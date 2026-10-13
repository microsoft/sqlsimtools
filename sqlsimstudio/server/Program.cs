using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using SqlsimStudio;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

const string SessionCookieName = "sqlsimstudio_session";

StudioOptions studioOptions;
try
{
    studioOptions = StudioOptions.Parse(args);
}
catch (ArgumentException error)
{
    Console.Error.WriteLine($"sqlsimstudio: {error.Message}");
    Console.Error.WriteLine("Usage: sqlsimstudio [--no-open --bootstrap-file <path>] [--port <port>]");
    return 2;
}

if (studioOptions.ShowHelp)
{
    Console.WriteLine("sqlsim Studio");
    Console.WriteLine("Usage: sqlsimstudio [--no-open --bootstrap-file <path>] [--port <port>]");
    Console.WriteLine();
    Console.WriteLine("  --no-open                 Do not open a browser. Requires --bootstrap-file.");
    Console.WriteLine("  --bootstrap-file <path>   Write the one-time sign-in URL here.");
    Console.WriteLine("  --port <port>             Listen on this loopback port instead of a free one.");
    Console.WriteLine();
    Console.WriteLine("Studio runs until it is stopped. Use Shut down in the interface, which also");
    Console.WriteLine("terminates any running workload and removes its temporary files. If Studio is");
    Console.WriteLine("killed instead, run sqlsimstudio-cleanup.ps1 to collect what it left behind.");
    Console.WriteLine();
    Console.WriteLine("Closing the browser does not stop Studio. The session URL is kept in");
    Console.WriteLine("sqlsimstudio-session-<user>.url under the temporary directory (on Linux,");
    Console.WriteLine("~/.local/share/sqlsimstudio/session.url), so the interface can be reopened.");
    return 0;
}

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args
});
builder.Logging.ClearProviders();
builder.Services.AddSingleton<StudioRunManager>();
builder.Services.AddSingleton(new StudioSettingsStore(StudioSettingsStore.DefaultDirectory()));
builder.WebHost.ConfigureKestrel(serverOptions =>
{
    serverOptions.AddServerHeader = false;
    serverOptions.Limits.MaxRequestBodySize = 105_000_000;
    serverOptions.Listen(IPAddress.Loopback, studioOptions.Port);
});

var app = builder.Build();
var runManager = app.Services.GetRequiredService<StudioRunManager>();
app.Lifetime.ApplicationStopping.Register(runManager.Cleanup);
var sessionToken = CreateToken();
var bootstrapToken = CreateToken();
// Set once Kestrel publishes its address, so the request pipeline can rewrite
// the session file with a replacement token.
var listeningAddress = string.Empty;
// Studio runs until it is told to stop, either from the Shutdown button or by
// being killed. It does not watch the browser and does not try to infer intent
// from silence: every version that did mistook a backgrounded tab, a frozen
// tab, or a sleeping machine for a user who had gone away, and stopped a
// session that was still in use. A workload now outlives the page that started
// it, which is the right behaviour for a load test.
//
// The exits are: the Shutdown button, which cleans up properly; and a hard
// kill, for which sqlsimstudio-cleanup.ps1 collects whatever was left behind.

app.Use(async (context, next) =>
{
    AddSecurityHeaders(context.Response);

    if (!IPAddress.IsLoopback(context.Connection.RemoteIpAddress ?? IPAddress.None) ||
        !IsAllowedHost(context.Request.Host.Host))
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        return;
    }

    var bootstrapPath = $"/bootstrap/{Volatile.Read(ref bootstrapToken)}";
    if (context.Request.Path == bootstrapPath)
    {
        context.Response.Cookies.Append(SessionCookieName, sessionToken, new CookieOptions
        {
            HttpOnly = true,
            IsEssential = true,
            SameSite = SameSiteMode.Strict,
            Path = "/"
        });
        // Each token opens exactly one session, but the file is immediately
        // refilled with a new one. Closing the browser is therefore not fatal:
        // Studio keeps running and the file still holds a way back in. The
        // spent token stops working the moment it is replaced.
        var nextToken = CreateToken();
        Volatile.Write(ref bootstrapToken, nextToken);
        WriteBootstrapFile(
            studioOptions.BootstrapFile ?? ReconnectFilePath(),
            listeningAddress,
            nextToken);
        context.Response.StatusCode = StatusCodes.Status302Found;
        context.Response.Headers.Location = "/#configure";
        return;
    }

    if (!context.Request.Cookies.TryGetValue(SessionCookieName, out var presentedToken) ||
        !TokensMatch(sessionToken, presentedToken))
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        return;
    }

    if (HttpMethods.IsPost(context.Request.Method) ||
        HttpMethods.IsPut(context.Request.Method) ||
        HttpMethods.IsPatch(context.Request.Method) ||
        HttpMethods.IsDelete(context.Request.Method))
    {
        var expectedOrigin = $"{context.Request.Scheme}://{context.Request.Host}";
        if (!string.Equals(context.Request.Headers.Origin, expectedOrigin, StringComparison.Ordinal))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }
    }

    await next();
});

var assets = StudioAssets.Load();
// The saved theme is written into the page itself, so it applies before the
// first paint instead of after a request completes.
const string IndexHtmlTag = "<html lang=\"en\">";
var indexHtml = Encoding.UTF8.GetString(assets["index.html"]);
if (!indexHtml.Contains(IndexHtmlTag, StringComparison.Ordinal))
{
    throw new InvalidOperationException("Embedded index.html is missing its <html lang=\"en\"> tag.");
}
IResult ServeIndex(StudioSettingsStore settings)
{
    // ReadTheme returns only allow-listed values, so the attribute needs no escaping.
    var theme = settings.ReadTheme();
    var html = theme is null
        ? indexHtml
        : indexHtml.Replace(IndexHtmlTag, $"<html lang=\"en\" data-saved-theme=\"{theme}\">", StringComparison.Ordinal);
    return Results.Text(html, "text/html; charset=utf-8");
}
var releaseStage = OperatingSystem.IsLinux() ||
    OperatingSystem.IsMacOS() ||
    (OperatingSystem.IsWindows() && RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
    ? "Private Preview"
    : "Public Preview";
app.MapGet("/", (StudioSettingsStore settings) => ServeIndex(settings));
app.MapGet("/index.html", (StudioSettingsStore settings) => ServeIndex(settings));
app.MapGet("/styles.css", () => Results.File(assets["styles.css"], "text/css; charset=utf-8"));
app.MapGet("/app.js", () => Results.File(assets["app.js"], "text/javascript; charset=utf-8"));
app.MapGet("/vendor/lucide.min.js", () => Results.File(assets["vendor/lucide.min.js"], "text/javascript; charset=utf-8"));
app.MapGet("/assets/sqlsim-icon.svg", () => Results.File(assets["sqlsim-icon.svg"], "image/svg+xml"));

app.MapGet("/api/health", () => Results.Ok(new
{
    status = "ok",
    application = "sqlsim Studio",
    version = typeof(StudioOptions).Assembly.GetName().Version?.ToString(3) ?? "1.0.0",
    releaseStage,
    os = RuntimeInformation.OSDescription,
    architecture = RuntimeInformation.OSArchitecture.ToString(),
    // ODBC Driver 18 implements interactive Entra sign-in on Windows only.
    supportsEntraInteractive = OperatingSystem.IsWindows(),
    browsers = new[] { "Edge", "Chrome", "Firefox", "Safari" }
}));

app.MapGet("/api/engines", async () => Results.Ok(await StudioEngineVersions.GetAsync()));

app.MapGet("/api/runs/current", (StudioRunManager runs) => Results.Ok(runs.GetSnapshot()));
app.MapGet("/api/runs/history", (StudioRunManager runs) => Results.Ok(runs.GetHistory()));

app.MapGet("/api/settings", (StudioSettingsStore settings) =>
    Results.Ok(new { theme = settings.ReadTheme() }));

app.MapPut("/api/settings", (AppSettingsRequest request, StudioSettingsStore settings) =>
{
    if (request.Theme is null || !StudioSettingsStore.Themes.Contains(request.Theme))
    {
        return Results.BadRequest(new
        {
            error = $"Theme must be one of: {string.Join(", ", StudioSettingsStore.Themes)}."
        });
    }

    return settings.WriteTheme(request.Theme)
        ? Results.Ok(new { theme = request.Theme })
        : Results.Json(new { error = "Studio could not save its settings file." }, statusCode: StatusCodes.Status500InternalServerError);
});

app.MapPost("/api/runs", (QueryRunRequest request, StudioRunManager runs) =>
{
    var result = runs.Start(request);
    return result.Success
        ? Results.Accepted("/api/runs/current", result)
        : Results.BadRequest(result);
});

app.MapPost("/api/connection-test", async (QueryRunRequest request, StudioRunManager runs) =>
    Results.Ok(await runs.TestConnectionAsync(request)));

app.MapDelete("/api/runs/current", (StudioRunManager runs) =>
    runs.Stop() ? Results.Accepted() : Results.NotFound());

// The only deliberate way to stop Studio. There is no console to press Ctrl+C
// in: the binary is a GUI subsystem process, so a double click gives no
// console at all, and launching it from a terminal returns to the prompt
// immediately rather than holding the foreground. Without this endpoint, Task
// Manager is the sole exit.
//
// Stopping runs ApplicationStopping, and therefore StudioRunManager.Cleanup,
// which kills any sqlsim process tree and deletes the private run directory.
app.MapPost("/api/session/shutdown", (StudioRunManager runs) =>
{
    var runState = runs.GetSnapshot().State;
    // Reply before stopping. Kestrel will not flush a response written during
    // its own shutdown, so the page would see a failed request and report that
    // Studio had crashed rather than closed.
    _ = Task.Run(async () =>
    {
        await Task.Delay(250);
        app.Lifetime.StopApplication();
    });
    return Results.Ok(new { stopping = true, runState });
});

await app.StartAsync();

var server = app.Services.GetRequiredService<IServer>();
var addresses = server.Features.Get<IServerAddressesFeature>()?.Addresses;
var baseAddress = addresses?.SingleOrDefault()
    ?? throw new InvalidOperationException("Kestrel did not publish a listening address.");
listeningAddress = baseAddress;
var bootstrapAddress = $"{baseAddress}/bootstrap/{Volatile.Read(ref bootstrapToken)}";

Console.WriteLine($"SQLSIM_STUDIO_URL={baseAddress}");
if (studioOptions.NoOpen)
{
    WriteBootstrapFile(studioOptions.BootstrapFile!, baseAddress, Volatile.Read(ref bootstrapToken));
    Console.WriteLine("SQLSIM_STUDIO_BOOTSTRAP_READY=1");
}
else
{
    // The file is written even when a browser is opened, so the session can be
    // reached again after the tab is closed. Studio no longer stops itself, so
    // without this a closed tab would strand a running process with no way
    // back in: the token that opened it has already been replaced.
    WriteBootstrapFile(ReconnectFilePath(), baseAddress, Volatile.Read(ref bootstrapToken));
    OpenBrowser(bootstrapAddress);
}

await app.WaitForShutdownAsync();
DeleteBootstrapFile(studioOptions.BootstrapFile ?? ReconnectFilePath());
return 0;

static string CreateToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32));

static bool TokensMatch(string expected, string? presented)
{
    if (presented is null)
    {
        return false;
    }

    var expectedBytes = Encoding.UTF8.GetBytes(expected);
    var presentedBytes = Encoding.UTF8.GetBytes(presented);
    return expectedBytes.Length == presentedBytes.Length &&
        CryptographicOperations.FixedTimeEquals(expectedBytes, presentedBytes);
}

static bool IsAllowedHost(string host) =>
    string.Equals(host, "127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
    string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase) ||
    string.Equals(host, "::1", StringComparison.OrdinalIgnoreCase);

static void AddSecurityHeaders(HttpResponse response)
{
    response.Headers.CacheControl = "no-store";
    response.Headers.XContentTypeOptions = "nosniff";
    response.Headers.XFrameOptions = "DENY";
    response.Headers["Referrer-Policy"] = "no-referrer";
    response.Headers["Content-Security-Policy"] =
        "default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; " +
        "img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; " +
        "form-action 'self'; frame-ancestors 'none'";
    response.Headers["Permissions-Policy"] =
        "camera=(), microphone=(), geolocation=(), payment=(), usb=()";
}

static void OpenBrowser(string url)
{
    try
    {
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }
    catch (Exception error)
    {
        Console.Error.WriteLine($"Unable to open the default browser: {error.Message}");
        Console.Error.WriteLine($"Open this URL manually: {url}");
    }
}

static void WriteBootstrapFile(string path, string baseAddress, string token)
{
    var fullPath = Path.GetFullPath(path);
    var directory = Path.GetDirectoryName(fullPath);
    if (!string.IsNullOrWhiteSpace(directory))
    {
        if (string.Equals(fullPath, Path.GetFullPath(StudioPaths.SessionFile), StringComparison.Ordinal))
        {
            StudioPaths.CreatePrivateDirectory(directory);
        }
        else
        {
            Directory.CreateDirectory(directory);
        }
    }
    try
    {
        File.WriteAllText(fullPath, $"{baseAddress}/bootstrap/{token}", new UTF8Encoding(false));
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(fullPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException)
    {
        // Losing the reconnect file costs the user a way back into a running
        // session; it must not take the session itself down.
        Console.Error.WriteLine("Warning: Studio could not write its session file.");
    }
}

// Where a running instance publishes the URL that reopens its interface. One
// file per user, so a second instance replaces the first entry rather than
// colliding with another account's. On Linux it lives in an owner-only
// directory rather than the shared /tmp; see StudioPaths.
static string ReconnectFilePath() => StudioPaths.SessionFile;

static void DeleteBootstrapFile(string? path)
{
    if (string.IsNullOrWhiteSpace(path))
    {
        return;
    }
    try
    {
        File.Delete(Path.GetFullPath(path));
    }
    catch (IOException)
    {
        Console.Error.WriteLine("Warning: Studio could not delete its bootstrap file.");
    }
    catch (UnauthorizedAccessException)
    {
        Console.Error.WriteLine("Warning: Studio could not delete its bootstrap file.");
    }
}

internal sealed record StudioOptions(bool NoOpen, int Port, bool ShowHelp, string? BootstrapFile)
{
    public static StudioOptions Parse(string[] arguments)
    {
        var noOpen = false;
        var port = 0;
        var showHelp = false;
        string? bootstrapFile = null;

        for (var index = 0; index < arguments.Length; index++)
        {
            switch (arguments[index])
            {
                case "--no-open":
                    noOpen = true;
                    break;
                case "--help":
                case "-h":
                    showHelp = true;
                    break;
                case "--port" when index + 1 < arguments.Length &&
                    int.TryParse(arguments[++index], out var parsedPort) &&
                    parsedPort is >= 0 and <= 65535:
                    port = parsedPort;
                    break;
                case "--bootstrap-file" when index + 1 < arguments.Length:
                    bootstrapFile = arguments[++index];
                    break;
                default:
                    throw new ArgumentException($"Unknown or invalid option: {arguments[index]}");
            }
        }

        if (noOpen && string.IsNullOrWhiteSpace(bootstrapFile))
        {
            throw new ArgumentException("--no-open requires --bootstrap-file <path>.");
        }

        return new StudioOptions(noOpen, port, showHelp, bootstrapFile);
    }
}

internal static class StudioAssets
{
    public static IReadOnlyDictionary<string, byte[]> Load()
    {
        var assembly = typeof(StudioAssets).Assembly;
        return new Dictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["index.html"] = Read(assembly, "SqlsimStudio.Assets.index.html"),
            ["styles.css"] = Read(assembly, "SqlsimStudio.Assets.styles.css"),
            ["app.js"] = Read(assembly, "SqlsimStudio.Assets.app.js"),
            ["vendor/lucide.min.js"] = Read(assembly, "SqlsimStudio.Assets.vendor.lucide.min.js"),
            ["sqlsim-icon.svg"] = Read(assembly, "SqlsimStudio.Assets.sqlsim-icon.svg")
        };
    }

    private static byte[] Read(System.Reflection.Assembly assembly, string name)
    {
        using var stream = assembly.GetManifestResourceStream(name)
            ?? throw new InvalidOperationException($"Embedded Studio asset is missing: {name}");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }
}
