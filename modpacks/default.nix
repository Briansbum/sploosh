# Registry of all modpacks.
# Each entry is passed to mkModpack in _lib.nix.
# Add a new modpack by adding an entry here and creating the modpack directory.
{
  create-central = {
    displayName = "Create Central";
    mcVersion = "1.21.1";
    loader = "neoforge";
    modpackHash = "sha256-FAHxj1uB0FhYUQ58lCZNgVndmvh1RySIYrmwE1zWq/I=";
    jvmOpts = "-Xms4096M -Xmx24576M -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200";
  };

}
