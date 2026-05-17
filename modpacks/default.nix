# Registry of all modpacks.
# Each entry is passed to mkModpack in _lib.nix.
# Add a new modpack by adding an entry here and creating the modpack directory.
{
  create-central = {
    displayName = "Create Central";
    mcVersion = "1.21.1";
    loader = "neoforge";
    modpackHash = "sha256-WfCY15x7LaXGV1Ou/x5zQ3J5CiF+ZSDDMBbzLnjn7u4=";
    jvmOpts = "-Xms4096M -Xmx12288M -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200";
  };

}
