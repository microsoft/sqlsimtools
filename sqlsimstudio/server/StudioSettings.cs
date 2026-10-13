using System.Text;
using System.Text.Json;

namespace SqlsimStudio;

// Per-user app preferences that must outlive one Studio session. Studio listens
// on a new loopback port at every launch and browsers scope local storage to
// the port, so the browser alone forgets them on restart.
internal sealed class StudioSettingsStore
{
    public const string DirectoryVariable = "SQLSIMSTUDIO_SETTINGS_DIR";

    public static readonly IReadOnlySet<string> Themes = new HashSet<string>(StringComparer.Ordinal)
    {
        "system", "light", "dark", "blue", "red-blue", "royal-blue", "green", "green-black", "green-gold"
    };

    private readonly string directory;
    private readonly string path;
    private readonly Lock gate = new();

    public StudioSettingsStore(string directory)
    {
        this.directory = directory;
        path = Path.Combine(directory, "settings.json");
    }

    // Tests set SQLSIMSTUDIO_SETTINGS_DIR so they never overwrite the user's
    // real preferences.
    public static string DefaultDirectory()
    {
        var overrideDirectory = Environment.GetEnvironmentVariable(DirectoryVariable);
        if (!string.IsNullOrWhiteSpace(overrideDirectory))
        {
            return Path.GetFullPath(overrideDirectory);
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create),
            "sqlsimstudio");
    }

    // A missing, unreadable, or hand-edited file yields no saved theme rather
    // than an error: a preference must never stop Studio from starting.
    public string? ReadTheme()
    {
        lock (gate)
        {
            try
            {
                if (!File.Exists(path))
                {
                    return null;
                }

                using var document = JsonDocument.Parse(File.ReadAllText(path));
                if (document.RootElement.ValueKind == JsonValueKind.Object &&
                    document.RootElement.TryGetProperty("theme", out var theme) &&
                    theme.ValueKind == JsonValueKind.String &&
                    theme.GetString() is { } value &&
                    Themes.Contains(value))
                {
                    return value;
                }

                return null;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
            {
                return null;
            }
        }
    }

    public bool WriteTheme(string theme)
    {
        if (!Themes.Contains(theme))
        {
            throw new ArgumentOutOfRangeException(nameof(theme), theme, "Unknown theme.");
        }

        lock (gate)
        {
            var temporaryPath = $"{path}.tmp";
            try
            {
                Directory.CreateDirectory(directory);
                File.WriteAllText(temporaryPath, JsonSerializer.Serialize(new { theme }), new UTF8Encoding(false));
                if (!OperatingSystem.IsWindows())
                {
                    File.SetUnixFileMode(temporaryPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                }
                File.Move(temporaryPath, path, overwrite: true);
                return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (Exception cleanupError) when (cleanupError is IOException or UnauthorizedAccessException)
                {
                }
                return false;
            }
        }
    }
}

internal sealed record AppSettingsRequest(string? Theme);
