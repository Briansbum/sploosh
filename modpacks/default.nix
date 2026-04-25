# Registry of all modpacks.
# Each entry is passed to mkModpack in _lib.nix.
# Add a new modpack by adding an entry here and creating the modpack directory.
{
  create-central = {
    displayName = "Create Central";
    mcVersion = "1.21.1";
    loader = "neoforge";
    # sha256 hash of the entire fetched modpack tree — set to lib.fakeHash until resolved:
    #   nix build .#modpacks.create-central.mrpack
    # modpackHash = "sha256-...";
    jvmOpts = "-Xms2048M -Xmx8192M -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200";
  };

}
