# Registry of all modpacks.
# Each entry is passed to mkModpack in _lib.nix.
# Add a new modpack by adding an entry here and creating the modpack directory.
{
  create-central = {
    displayName = "Create Central";
    mcVersion = "1.21.1";
    loader = "neoforge";
    modpackHash = "sha256-Bvax9JBOwuDpWT0mXPwEe3JlBxYz4et4kW310d+wHXA=";
    jvmOpts = "-Xms10G -Xmx10G -XX:+UseZGC -XX:+ZGenerational -XX:+AlwaysPreTouch -XX:SoftMaxHeapSize=8g -XX:+UseLargePages -XX:+UseTransparentHugePages -XX:+DisableExplicitGC -XX:ZCollectionInterval=5 -XX:ConcGCThreads=1";
  };

}
