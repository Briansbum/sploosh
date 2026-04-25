// EC2 API helpers using the query API (application/x-www-form-urlencoded).
import { signRequest } from "./sigv4";
import type { Env } from "../types";

function ec2Creds(env: Env) {
  return {
    accessKeyId: env.AWS_ACCESS_KEY_ID,
    secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
    region: env.AWS_REGION,
    service: "ec2",
  };
}

async function ec2Query(env: Env, params: Record<string, string>): Promise<Document> {
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
  if (!res.ok) throw new Error(`EC2 error ${res.status}: ${text}`);
  return new DOMParser().parseFromString(text, "text/xml");
}

/** Set EC2 Fleet target capacity (0=stop, 1=start) */
export async function setFleetCapacity(env: Env, fleetId: string, capacity: number): Promise<void> {
  await ec2Query(env, {
    Action: "ModifyFleet",
    FleetId: fleetId,
    "TargetCapacitySpecification.TotalTargetCapacity": String(capacity),
    "TargetCapacitySpecification.DefaultTargetCapacityType": "spot",
  });
}

/** Get the running instance for a fleet (returns null if no instance yet) */
export async function getFleetInstance(
  env: Env,
  fleetId: string,
): Promise<{ instanceId: string; publicIp: string } | null> {
  const doc = await ec2Query(env, {
    Action: "DescribeFleetInstances",
    FleetId: fleetId,
  });
  const instanceId = doc.querySelector("instanceId")?.textContent?.trim() ?? null;
  if (!instanceId) return null;

  // Get public IP from DescribeInstances
  const doc2 = await ec2Query(env, {
    Action: "DescribeInstances",
    "InstanceId.1": instanceId,
  });
  const publicIp = doc2.querySelector("ipAddress")?.textContent?.trim() ?? "";
  return { instanceId, publicIp };
}

/** Authorize a single IP /32 on port 25565 in the security group */
export async function authorizeSgIngress(
  env: Env,
  sgId: string,
  ip: string,
): Promise<string> {
  const doc = await ec2Query(env, {
    Action: "AuthorizeSecurityGroupIngress",
    GroupId: sgId,
    "IpPermissions.1.IpProtocol": "tcp",
    "IpPermissions.1.FromPort": "25565",
    "IpPermissions.1.ToPort": "25565",
    "IpPermissions.1.IpRanges.1.CidrIp": `${ip}/32`,
    "IpPermissions.1.IpRanges.1.Description": "sploosh-allowlist",
  });
  // The response includes the rule ID we need to revoke later
  const ruleId =
    doc.querySelector("securityGroupRuleId")?.textContent?.trim() ??
    `${sgId}:${ip}`; // fallback key if API doesn't return it
  return ruleId;
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
