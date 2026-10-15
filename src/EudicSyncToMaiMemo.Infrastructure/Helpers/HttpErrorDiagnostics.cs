using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Encodings.Web;
using System.Text.RegularExpressions;

namespace EudicSyncToMaiMemo.Infrastructure.Helpers;

/// <summary>只用于失败诊断，不改变实际发送的请求或成功响应。</summary>
internal static class HttpErrorDiagnostics
{
    private const string Redacted = "[REDACTED]";
    private const int MaxBodyLength = 4096;
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(1);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    private const string SensitiveName =
        @"[\w-]*(?:authorization|token|cookie|password|passwd|secret|credential|api[_-]?key|session|email|phone)[\w-]*";

    // 仅保留诊断字段，避免把服务器回显的请求、凭证或业务内容写入日志。
    private static readonly HashSet<string> DiagnosticFields = new(StringComparer.OrdinalIgnoreCase)
    {
        "success", "status", "status_code", "code", "error", "errors", "message", "msg",
        "detail", "details", "description", "reason", "type", "error_code", "error_type",
        "error_description", "field", "location"
    };

    public static async Task<(string Url, string Body)> CreateAsync(
        HttpRequestMessage request, string body, CancellationToken cancellationToken)
    {
        var secrets = new HashSet<string>(StringComparer.Ordinal);
        foreach (var header in request.Headers)
        {
            if (IsSensitiveName(header.Key))
            {
                foreach (string value in header.Value)
                {
                    AddSensitiveValue(secrets, value, header.Key.Contains("cookie", StringComparison.OrdinalIgnoreCase));
                }
            }
        }

        string url = SanitizeUrl(request.RequestUri!, secrets);
        // Form/JSON 请求体不输出，仅收集敏感值以防服务器在 message 中回显。
        if (request.Content is StringContent or FormUrlEncodedContent)
        {
            string content = await request.Content.ReadAsStringAsync(cancellationToken);
            if (request.Content is FormUrlEncodedContent)
            {
                foreach (string pair in content.Split('&'))
                {
                    string[] parts = pair.Split('=', 2);
                    if (parts.Length == 2 && IsSensitiveName(Uri.UnescapeDataString(parts[0])))
                    {
                        AddSecret(secrets, Uri.UnescapeDataString(parts[1].Replace('+', ' ')));
                    }
                }
            }
            else
            {
                try
                {
                    CollectSensitiveValues(JsonNode.Parse(content), secrets);
                }
                catch (JsonException) { /* 不输出请求体。 */ }
            }
        }

        body = SanitizeJson(body, secrets);
        try
        {
            body = Regex.Replace(body, @"https?://[^\s<>""\\]+",
                match => Uri.TryCreate(match.Value, UriKind.Absolute, out var uri)
                    ? SanitizeUrl(uri, secrets) : "[URL omitted]",
                RegexOptions.IgnoreCase, RegexTimeout);
            body = Regex.Replace(body,
                $"\\b{SensitiveName}[\"']?\\s*[:=]\\s*(?:\"[^\"]*\"|'[^']*'|[^\\r\\n,}}]+)",
                _ => Redacted, RegexOptions.IgnoreCase | RegexOptions.NonBacktracking, RegexTimeout);
            body = Regex.Replace(body, @"\b(?:Bearer|Basic|NIS)\s+[^\s""',;<>]+",
                _ => Redacted, RegexOptions.IgnoreCase, RegexTimeout);
            body = Regex.Replace(body, @"\beyJ[\w-]+\.[\w-]+\.[\w-]+\b",
                _ => Redacted, RegexOptions.None, RegexTimeout);
        }
        catch (RegexMatchTimeoutException)
        {
            body = "[错误响应脱敏超时，正文已隐藏]";
        }

        // 先脱敏再截断，防止截断使凭证失去可识别的边界。
        foreach (string secret in secrets.OrderByDescending(value => value.Length))
        {
            foreach (string variant in new[] { secret, Uri.EscapeDataString(secret),
                         JsonEncodedText.Encode(secret).ToString(), System.Net.WebUtility.HtmlEncode(secret) })
            {
                body = body.Replace(variant, Redacted, StringComparison.Ordinal);
                url = url.Replace(variant, Redacted, StringComparison.Ordinal);
            }
        }

        body = string.Concat(body.Select(character => char.IsControl(character) ? ' ' : character));
        if (string.IsNullOrWhiteSpace(body)) body = "[空响应正文]";
        if (body.Length > MaxBodyLength) body = body[..MaxBodyLength] + " [truncated]";
        return (url, body);
    }

    private static string SanitizeJson(string text, HashSet<string> secrets)
    {
        try
        {
            var node = JsonNode.Parse(text);
            CollectSensitiveValues(node, secrets);
            RedactNode(node);
            return node?.ToJsonString(JsonOptions) ?? text;
        }
        catch (JsonException)
        {
            // 网关也可能返回纯文本或 HTML；仍需经过文本脱敏。
            return text;
        }
    }

    private static void RedactNode(JsonNode? node)
    {
        if (node is JsonObject obj)
        {
            foreach (var property in obj.ToArray())
            {
                if (IsSensitiveName(property.Key) || !DiagnosticFields.Contains(property.Key))
                {
                    obj[property.Key] = Redacted;
                }
                else RedactNode(property.Value);
            }
        }
        else if (node is JsonArray array)
        {
            foreach (var child in array) RedactNode(child);
        }
    }

    private static void CollectSensitiveValues(JsonNode? node, HashSet<string> secrets)
    {
        if (node is JsonObject obj)
        {
            foreach (var property in obj)
            {
                if (IsSensitiveName(property.Key))
                    CollectValues(property.Value, secrets, property.Key.Contains("cookie", StringComparison.OrdinalIgnoreCase));
                else CollectSensitiveValues(property.Value, secrets);
            }
        }
        else if (node is JsonArray array)
            foreach (var child in array) CollectSensitiveValues(child, secrets);
    }

    private static void CollectValues(JsonNode? node, HashSet<string> secrets, bool cookie)
    {
        if (node is JsonValue value && value.TryGetValue<string>(out var text)) AddSensitiveValue(secrets, text, cookie);
        else if (node is JsonObject obj)
            foreach (var property in obj) CollectValues(property.Value, secrets, cookie);
        else if (node is JsonArray array)
            foreach (var child in array) CollectValues(child, secrets, cookie);
    }

    private static string SanitizeUrl(Uri uri, HashSet<string> secrets)
    {
        AddSecret(secrets, uri.UserInfo);
        foreach (string part in uri.UserInfo.Split(':')) AddSecret(secrets, part);
        AddSecret(secrets, uri.Fragment.TrimStart('#'));
        var builder = new UriBuilder(uri) { UserName = "", Password = "", Fragment = "", Query = "" };
        foreach (string pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            string[] parts = pair.Split('=', 2);
            if (parts.Length == 2) AddSecret(secrets, Uri.UnescapeDataString(parts[1].Replace('+', ' ')));
        }
        // 路径保留用于定位接口，查询值一律隐藏（包括名称不常见的凭证）。
        return builder.Uri.AbsoluteUri + (uri.Query.Length > 0 ? "?[REDACTED]" : "");
    }

    private static bool IsSensitiveName(string name) =>
        Regex.IsMatch(name, SensitiveName, RegexOptions.IgnoreCase | RegexOptions.NonBacktracking, RegexTimeout);

    private static void AddSensitiveValue(HashSet<string> secrets, string value, bool cookie)
    {
        AddSecret(secrets, value);
        // 响应可能只回显凭证部分，而不带认证方案。
        foreach (string scheme in new[] { "Bearer ", "Basic ", "NIS " })
            if (value.StartsWith(scheme, StringComparison.OrdinalIgnoreCase))
                AddSecret(secrets, value[scheme.Length..].Trim());
        if (cookie)
            foreach (string pair in value.Split(';'))
            {
                string[] parts = pair.Split('=', 2);
                if (parts.Length == 2) AddSecret(secrets, parts[1].Trim());
            }
    }

    private static void AddSecret(HashSet<string> secrets, string value)
    {
        if (!string.IsNullOrWhiteSpace(value)) secrets.Add(value);
    }
}
