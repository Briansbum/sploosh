# Registry of all modpacks.
# Each entry is passed to mkModpack in _lib.nix.
# Add a new modpack by adding an entry here and creating the modpack directory.
{
  create-central = {
    displayName = "Create Central";
    mcVersion = "1.21.1";
    loader = "neoforge";
    modpackHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    jvmOpts = "-Xms2048M -Xmx8192M -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200";
  };

}
