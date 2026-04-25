// Runs every 5 minutes via Cron trigger.
// 1. Reconcile server_state against EC2 Fleet/DescribeInstances
// 2. Sweep expired allowlist entries and revoke their SG rules
import { listModpacks, getServerState, setServerStatus, getExpiredAllowlist, removeAllowlist } from "./db";
import { getFleetInstance, describeFleet, revokeSgIngress, authorizeSgIngress } from "./aws/ec2";
import type { Env } from "./types";

export async function handleScheduled(env: Env): Promise<void> {
  await Promise.allSettled([reconcileServers(env), sweepAllowlist(env)]);
}

async function reconcileServers(env: Env): Promise<void> {
  const modpacks = await listModpacks(env);

  for (const mp of modpacks) {
    if (!mp.fleet_id) continue;

    const [state, instance, fleetInfo] = await Promise.all([
      getServerState(env, mp.name),
      getFleetInstance(env, mp.fleet_id),
      describeFleet(env, mp.fleet_id),
    ]);

    const fleetWindingDown =
      fleetInfo?.state === "request-canceled-and-instance-running" ||
      fleetInfo?.state === "delete-requested" ||
      fleetInfo?.state === "deleted" ||
      fleetInfo?.activityStatus === "pending-termination";

    if (instance?.publicIp && !fleetWindingDown) {
      // Fleet has a running instance and is healthy
      if (state?.status !== "running" || state.instance_id !== instance.instanceId) {
        await setServerStatus(env, mp.name, "running", instance.instanceId, instance.publicIp);

        // Ensure all allowlisted IPs have SG rules (handles the case where
        // the server was (re)started but some rules weren't added yet)
        const { results } = await env.DB.prepare(
          "SELECT * FROM allowlist WHERE modpack=? AND sg_rule_id=''",
        )
          .bind(mp.name)
          .all<{ discord_user_id: string; ip: string }>();
        for (const row of results) {
          try {
            const ruleId = await authorizeSgIngress(env, mp.security_group_id, row.ip);
            await env.DB.prepare("UPDATE allowlist SET sg_rule_id=? WHERE modpack=? AND discord_user_id=?")
              .bind(ruleId, mp.name, row.discord_user_id)
              .run();
          } catch {
            // Continue — individual IP errors shouldn't block the rest
          }
        }
      }
    } else if (instance?.publicIp && fleetWindingDown) {
      // Instance still up but fleet is cancelling — mark stopping so status is accurate
      if (state?.status !== "stopping") {
        await setServerStatus(env, mp.name, "stopping");
      }
    } else {
      // No running instance
      if (state?.status === "running" || state?.status === "starting") {
        // Only flip to stopped if we've been waiting a long time (not just starting)
        const staleMs = 15 * 60 * 1000; // 15 min
        if (state.last_seen && Date.now() - state.last_seen > staleMs) {
          await setServerStatus(env, mp.name, "stopped", null, null);
        }
      } else if (state?.status === "stopping") {
        await setServerStatus(env, mp.name, "stopped", null, null);
      }
    }
  }
}

async function sweepAllowlist(env: Env): Promise<void> {
  const expired = await getExpiredAllowlist(env);

  // Get security group IDs once
  const { results: modpacks } = await env.DB.prepare(
    "SELECT name, security_group_id FROM modpacks",
  ).all<{ name: string; security_group_id: string }>();
  const sgMap = Object.fromEntries(modpacks.map((m) => [m.name, m.security_group_id]));

  for (const entry of expired) {
    if (entry.sg_rule_id && sgMap[entry.modpack]) {
      try {
        await revokeSgIngress(env, sgMap[entry.modpack], entry.sg_rule_id, entry.ip);
      } catch {
        // Already revoked or instance gone — fine
      }
    }
    await removeAllowlist(env, entry.modpack, entry.discord_user_id);
  }
}
