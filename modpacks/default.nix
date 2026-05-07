# Registry of all modpacks.
# Each entry is passed to mkModpack in _lib.nix.
# Add a new modpack by adding an entry here and creating the modpack directory.
{
  create-central = {
    displayName = "Create Central";
    mcVersion = "1.21.1";
    loader = "neoforge";
    modpackHash = "sha256-jgY/QeG2bUFSkOrk2dqEY1qzX6EfriSbblCALAT77J8=";
    jvmOpts = "-Xms4096M -Xmx24576M -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200";
  };

}
