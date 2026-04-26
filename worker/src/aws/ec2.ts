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

export interface FleetInfo {
  state: string;
  activityStatus: string;
}

export async function describeFleet(env: Env, fleetId: string): Promise<FleetInfo | null> {
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

const INSTANCE_TYPES = [
  "r5.xlarge", "r5a.xlarge", "r5n.xlarge", "r6i.xlarge",
  "m5.2xlarge", "m5a.2xlarge", "m6i.2xlarge", "m6a.2xlarge",
];
const AVAILABILITY_ZONES = ["eu-west-2a", "eu-west-2b", "eu-west-2c"];

export async function createFleet(env: Env, launchTemplateId: string): Promise<{ fleetId: string }> {
  const params: Record<string, string> = {
    Action: "CreateFleet",
    Type: "maintain",
    "TargetCapacitySpecification.TotalTargetCapacity": "1",
    "TargetCapacitySpecification.DefaultTargetCapacityType": "spot",
    "SpotOptions.AllocationStrategy": "price-capacity-optimized",
    "SpotOptions.InstanceInterruptionBehavior": "terminate",
    "OnDemandOptions.AllocationStrategy": "lowestPrice",
    ExcessCapacityTerminationPolicy: "termination",
    "LaunchTemplateConfigs.1.LaunchTemplateSpecification.LaunchTemplateId": launchTemplateId,
    "LaunchTemplateConfigs.1.LaunchTemplateSpecification.Version": "$Default",
  };

  let i = 1;
  for (const instanceType of INSTANCE_TYPES) {
    for (const az of AVAILABILITY_ZONES) {
      params[`LaunchTemplateConfigs.1.Overrides.${i}.InstanceType`] = instanceType;
      params[`LaunchTemplateConfigs.1.Overrides.${i}.AvailabilityZone`] = az;
      i++;
    }
  }

  const xml = await ec2Query(env, params);
  const fleetId = xmlTag(xml, "fleetId");
  if (!fleetId) throw new EC2Error("NoFleetId", "CreateFleet response missing fleetId");
  return { fleetId };
}

export async function deleteFleet(env: Env, fleetId: string): Promise<void> {
  await ec2Query(env, {
    Action: "DeleteFleets",
    "FleetId.1": fleetId,
    TerminateInstances: "true",
  });
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
