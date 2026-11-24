public enum PRBarCore {
    /// The version (`Scripts/release.sh` edits the `static let version` line below).
    ///
    /// Read through a private constant, not a public `let`: in release builds Swift copies a public constant into the
    /// modules that use it (PRBar, PRBarCLIKit), and an incremental build that only changes its value doesn't rebuild
    /// them, so the app and `prbar --version` kept reporting the previous version.
    public static var version: String { Current.version }

    private enum Current {
        static let version = "1.4.4"
    }
}
