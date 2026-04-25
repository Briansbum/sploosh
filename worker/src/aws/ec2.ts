// EC2 API helpers using the query API (application/x-www-form-urlencoded).
import { signRequest } from "./sigv4";
import type { Env } from "../types";

export class EC2Error extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "EC2Error";
  }
}

function ec2Creds(env: Env) {
  return {
    accessKeyId: env.AWS_ACCESS_KEY_ID,
    secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
    region: env.AWS_REGION,
    service: "ec2",
  };
}

async function ec2Query(env: Env, params: Record<string, string>): Promise<string> {
  const region = env.AWS_REGION;
  const url = `https://ec2.${region}.amazonaws.com/`;
  const body = new URLSearchParams({ Version: "2016-11-15", ...params }).toString();
  const req = await signRequest(
    new Request(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    }),
    ec2Creds(env),
  );
  const res = await fetch(req);
  const text = await res.text();
  if (!res.ok) {
    const code = xmlTag(text, "Code") ?? "Unknown";
    const message = xmlTag(text, "Message") ?? `HTTP ${res.status}`;
    throw new EC2Error(code, message);
  }
  return text;
}

function xmlTag(xml: string, tag: string): string | null {
  const m = xml.match(new RegExp(`<${tag}[^>]*>([^<]*)</${tag}>`));
  return m ? m[1].trim() : null;
}

interface FleetInfo {
  state: string;
  activityStatus: string;
}

async function describeFleet(env: Env, fleetId: string): Promise<FleetInfo | null> {
  try {
    const xml = await ec2Query(env, { Action: "DescribeFleets", "FleetId.1": fleetId });
    return {
      state: xmlTag(xml, "fleetState") ?? "unknown",
      activityStatus: xmlTag(xml, "activityStatus") ?? "unknown",
    };
  } catch {
    return null;
  }
}

function fleetStateMessage(info: FleetInfo, requestedCapacity: number): string | null {
  const { state, activityStatus } = info;
  if (state === "modifying") {
    return "A fleet modification is already in progress — try again in a moment.";
  }
  if (state === "delete-requested" || state === "deleted") {
    return "The fleet has been deleted and cannot accept modifications.";
  }
  if (state === "failed") {
    return "The fleet is in a failed state and cannot be modified.";
  }
  if (activityStatus === "pending-termination") {
    return requestedCapacity > 0
      ? "Spot instances are currently being terminated — wait for shutdown to complete before restarting."
      : "Spot instances are already being terminated.";
  }
  if (activityStatus === "pending-fulfillment" && requestedCapacity > 0) {
    return "Fleet is already waiting for instances to launch.";
  }
  return null;
}

/** Set EC2 Fleet target capacity (0=stop, 1=start) */
export async function setFleetCapacity(env: Env, fleetId: string, capacity: number): Promise<void> {
  try {
    await ec2Query(env, {
      Action: "ModifyFleet",
      FleetId: fleetId,
      "TargetCapacitySpecification.TotalTargetCapacity": String(capacity),
    });
  } catch (e) {
    const info = await describeFleet(env, fleetId);
    if (info) {
      const msg = fleetStateMessage(info, capacity);
      if (msg) throw new Error(msg);
    }
    throw e;
  }
}

/** Get the running instance for a fleet (returns null if no instance yet) */
export async function getFleetInstance(
  env: Env,
  fleetId: string,
): Promise<{ instanceId: string; publicIp: string } | null> {
  const xml = await ec2Query(env, {
    Action: "DescribeFleetInstances",
    FleetId: fleetId,
  });
  const instanceId = xmlTag(xml, "instanceId");
  if (!instanceId) return null;

  // Get public IP from DescribeInstances
  const xml2 = await ec2Query(env, {
    Action: "DescribeInstances",
    "InstanceId.1": instanceId,
  });
  const publicIp = xmlTag(xml2, "ipAddress") ?? "";
  return { instanceId, publicIp };
}

/** Authorize a single IP /32 on port 25565 in the security group */
export async function authorizeSgIngress(
  env: Env,
  sgId: string,
  ip: string,
): Promise<string> {
  const xml = await ec2Query(env, {
    Action: "AuthorizeSecurityGroupIngress",
    GroupId: sgId,
    "IpPermissions.1.IpProtocol": "tcp",
    "IpPermissions.1.FromPort": "25565",
    "IpPermissions.1.ToPort": "25565",
    "IpPermissions.1.IpRanges.1.CidrIp": `${ip}/32`,
    "IpPermissions.1.IpRanges.1.Description": "sploosh-allowlist",
  });
  return xmlTag(xml, "securityGroupRuleId") ?? `${sgId}:${ip}`;
}

/** Revoke a security group rule by rule ID */
export async function revokeSgIngress(
  env: Env,
  sgId: string,
  ruleId: string,
  ip: string,
): Promise<void> {
  // Try to revoke by rule ID first (newer API), fall back to CIDR
  try {
    await ec2Query(env, {
      Action: "RevokeSecurityGroupIngress",
      GroupId: sgId,
      "SecurityGroupRuleId.1": ruleId,
    });
  } catch {
    await ec2Query(env, {
      Action: "RevokeSecurityGroupIngress",
      GroupId: sgId,
      "IpPermissions.1.IpProtocol": "tcp",
      "IpPermissions.1.FromPort": "25565",
      "IpPermissions.1.ToPort": "25565",
      "IpPermissions.1.IpRanges.1.CidrIp": `${ip}/32`,
    });
  }
}
