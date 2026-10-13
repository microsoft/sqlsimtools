namespace SqlsimStudio;

// Where Studio keeps per-session files: private run directories and the URL
// file that reopens a running session.
//
// Windows and macOS give every user a private temporary directory, so those
// files live there. On Linux the temporary directory is the shared /tmp, where
// another local user could pre-create a path Studio uses, as a symlink that
// redirects deletions and writes into the user's own files, or as a file they
// can read the one-time sign-in token from. On Linux these files therefore
// live in an owner-only directory under the user's local application data.
internal static class StudioPaths
{
    private const UnixFileMode OwnerOnly = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;

    public static bool UsesSharedTemp => OperatingSystem.IsLinux();

    public static string RunRoot => UsesSharedTemp
        ? Path.Combine(PrivateRoot, "runs")
        : Path.Combine(Path.GetTempPath(), "sqlsimstudio");

    public static string SessionFile => UsesSharedTemp
        ? Path.Combine(PrivateRoot, "session.url")
        : Path.Combine(Path.GetTempPath(), $"sqlsimstudio-session-{Environment.UserName}.url");

    private static string PrivateRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create),
        "sqlsimstudio");

    // Creates a directory readable only by its owner on Unix, tightening the
    // mode if it already existed.
    public static void CreatePrivateDirectory(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(path);
            return;
        }

        Directory.CreateDirectory(path, OwnerOnly);
        File.SetUnixFileMode(path, OwnerOnly);
    }
}
