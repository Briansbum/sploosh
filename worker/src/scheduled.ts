// Runs every 5 minutes via Cron trigger.
// Reconciles server_state against EC2 Fleet/DescribeInstances. Allowlist
// entries no longer expire — /revoke is the only way to remove them.
import { listModpacks, getServerState, setServerStatus } from "./db";
import { getFleetInstance, describeFleet, revokeSgIngress, authorizeSgIngress } from "./aws/ec2";
import { setARecord } from "./cloudflare/dns";
import type { Env } from "./types";

export async function handleScheduled(env: Env): Promise<void> {
  await reconcileServers(env);
}

async function reconcileServers(env: Env): Promise<void> {
  const modpacks = await listModpacks(env);

  for (const mp of modpacks) {
    const state = await getServerState(env, mp.name);

    if (!state?.fleet_id) {
      // No active fleet — snap any stale non-stopped status back to stopped.
      if (state?.status && state.status !== "stopped") {
        await setServerStatus(env, mp.name, "stopped", null, null, null);
      }
      continue;
    }

    const [instance, fleetInfo] = await Promise.all([
      getFleetInstance(env, state.fleet_id),
      describeFleet(env, state.fleet_id),
    ]);

    const fleetWindingDown =
      fleetInfo?.state === "request-canceled-and-instance-running" ||
      fleetInfo?.state === "delete-requested" ||
      fleetInfo?.state === "deleted" ||
      fleetInfo?.activityStatus === "pending-termination";

    if (instance?.publicIp && !fleetWindingDown) {
      // Healthy fleet with a running instance.
      // Always call setServerStatus so last_seen stays fresh every cycle.
      // Without this, a server running for hours gets a stale last_seen, and
      // the next spot reclaim would look immediately stale and clear fleet_id.
      await setARecord(env, mp.name, instance.publicIp).catch((e) =>
        console.error(`DNS update failed for ${mp.name}:`, e),
      );

      const instanceChanged =
        state?.status !== "running" || state.instance_id !== instance.instanceId;

      await setServerStatus(
        env,
        mp.name,
        "running",
        instance.instanceId,
        instance.publicIp,
        state.fleet_id,
      );

      if (instanceChanged) {
        // Instance cycled (spot replacement) — re-apply SG rules for all
        // allowlisted IPs. Also handles SG recreation after tofu apply where
        // old rule IDs in D1 no longer exist in AWS.
        const { results } = await env.DB.prepare(
          "SELECT * FROM allowlist WHERE modpack=? AND ip != ''",
        )
          .bind(mp.name)
          .all<{ discord_user_id: string; ip: string; sg_rule_id: string }>();
        for (const row of results) {
          try {
            if (row.sg_rule_id) {
              await revokeSgIngress(env, mp.security_group_id, row.sg_rule_id, row.ip).catch(() => {});
            }
            const ruleId = await authorizeSgIngress(env, mp.security_group_id, row.ip);
            await env.DB.prepare(
              "UPDATE allowlist SET sg_rule_id=? WHERE modpack=? AND discord_user_id=?",
            )
              .bind(ruleId, mp.name, row.discord_user_id)
              .run();
          } catch {
            // Continue — individual IP errors shouldn't block the rest
          }
        }
      }
    } else if (fleetWindingDown) {
      // Fleet is being deleted (explicit /stop or idle shutdown).
      if (!instance?.publicIp) {
        // Instance gone — fully stopped, clear fleet_id.
        await setServerStatus(env, mp.name, "stopped", null, null, null);
      } else if (state?.status !== "stopping") {
        // Instance still running but fleet is cancelling — mark stopping.
        await setServerStatus(
          env,
          mp.name,
          "stopping",
          state.instance_id,
          state.public_ip,
          state.fleet_id,
        );
      }
    } else {
      // Fleet is active but has no running instance — spot replacement in progress.
      // Do NOT clear fleet_id here: the replacement instance needs it to register
      // via /server-heartbeat when it boots.
      if (state?.status === "running") {
        // Instance just vanished; transition to starting so users see accurate status.
        await setServerStatus(env, mp.name, "starting", null, null, state.fleet_id);
      } else if (state?.status === "starting") {
        // last_seen was refreshed when we last saw a healthy instance, so a
        // genuinely stuck fleet (failed to place) surfaces after 15 min.
        const staleMs = 15 * 60 * 1000;
        if (state.last_seen && Date.now() - state.last_seen > staleMs) {
          await setServerStatus(env, mp.name, "stopped", null, null, null);
        }
      }
    }
  }
}
