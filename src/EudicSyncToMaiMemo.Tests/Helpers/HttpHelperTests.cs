using System.Net;
using System.Net.Sockets;
using System.Text;
using EudicSyncToMaiMemo.Infrastructure.Helpers;
using Microsoft.Extensions.Logging;
using Moq;
using Xunit;

namespace EudicSyncToMaiMemo.Tests.Helpers;

public class HttpHelperTests
{
    private const string NotepadUrl = "https://open.maimemo.com/open/api/v1/memo/notepads/np-test";

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Failure_LogsStatusUrlAndServerError_AndDoesNotRetry(bool post)
    {
        using var handler = new StubHandler(_ => new(HttpStatusCode.BadRequest)
        {
            Content = new StringContent("""{"success":false,"errors":[{"code":"INVALID_ID","message":"云词本 ID 无效"}]}""")
        });
        var (helper, logger) = CreateHelper(handler);
        var exception = await Assert.ThrowsAsync<HttpRequestException>(() => post
            ? helper.PostAsync(NotepadUrl, "{}") : helper.GetAsync(NotepadUrl));

        Assert.Equal(HttpStatusCode.BadRequest, exception.StatusCode);
        Assert.Equal(1, handler.CallCount);
        string log = Assert.Single(logger.Messages);
        Assert.Contains("400", log);
        Assert.Contains(NotepadUrl, log);
        Assert.Contains(post ? "POST" : "GET", log);
        Assert.Contains("INVALID_ID", log);
        Assert.Contains("云词本 ID 无效", log);
        Assert.Contains("INVALID_ID", exception.Message);
    }

    [Fact]
    public async Task Failure_RedactsNestedCredentialsAndEchoedHeaderAndQueryValues()
    {
        const string body = """
            {"errors":[{"code":"BAD_REQUEST","message":"invalid request; auth-secret q-secret response-secret cookie-secret"}],
             "Authorization":"Bearer response-secret", "data":{"access_token":"nested-secret"},
             "Cookie":["response-cookie"], "email":"private@example.com"}
            """;
        using var handler = new StubHandler(_ => new(HttpStatusCode.BadRequest)
        {
            Content = new StringContent(body), ReasonPhrase = "Do not log reason-secret"
        });
        var (helper, logger) = CreateHelper(handler);
        var exception = await Assert.ThrowsAsync<HttpRequestException>(() => helper.GetAsync(
            NotepadUrl + "?custom=q-secret#fragment-secret", new()
            {
                ["Authorization"] = "Bearer auth-secret", ["Cookie"] = "sid=cookie-secret"
            }));

        string diagnostic = Assert.Single(logger.Messages) + exception;
        Assert.Contains("BAD_REQUEST", diagnostic);
        Assert.Contains("[REDACTED]", diagnostic);
        foreach (string secret in new[] { "auth-secret", "q-secret", "response-secret", "cookie-secret",
                     "nested-secret", "response-cookie", "private@example.com", "fragment-secret", "reason-secret" })
            Assert.DoesNotContain(secret, diagnostic);
    }

    [Theory]
    [InlineData("Bad request\nAuthorization: Bearer unknown-auth\nCookie: sid=unknown-cookie; other=another-cookie\npassword=unknown-password")]
    [InlineData("<html>Bad request <p>access_token=unknown-token</p> Bearer unknown-bearer</html>")]
    [InlineData("Bad request: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature")]
    [InlineData("Bad request: {\"token\":\"unknown-token\"")]
    public async Task Failure_SanitizesNonJsonResponses(string body)
    {
        using var handler = new StubHandler(_ => new(HttpStatusCode.BadRequest) { Content = new StringContent(body) });
        var (helper, logger) = CreateHelper(handler);
        var exception = await Assert.ThrowsAsync<HttpRequestException>(() => helper.GetAsync(NotepadUrl));

        string diagnostic = Assert.Single(logger.Messages) + exception;
        Assert.Contains("Bad request", diagnostic);
        Assert.DoesNotContain("unknown-", diagnostic);
        Assert.DoesNotContain("another-cookie", diagnostic);
        Assert.DoesNotContain("eyJ", diagnostic);
    }

    [Fact]
    public async Task Failure_RedactsEscapedSecretsFromRequestBodyAndUrlUserInfo()
    {
        using var handler = new StubHandler(_ => new(HttpStatusCode.BadRequest)
        {
            Content = new StringContent("""{"message":"echo p%40ss%2Bword; user:pass; body-secret"}""")
        });
        var (helper, logger) = CreateHelper(handler);
        var exception = await Assert.ThrowsAsync<HttpRequestException>(() => helper.PostAsync(
            "https://user:pass@example.com/test?unknown=p%40ss%2Bword", """{"password":"body-secret"}"""));

        string diagnostic = Assert.Single(logger.Messages) + exception;
        foreach (string secret in new[] { "p%40ss%2Bword", "user:pass", "body-secret" })
            Assert.DoesNotContain(secret, diagnostic);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public async Task Failure_HandlesEmptyBody(string body)
    {
        using var handler = new StubHandler(_ => new(HttpStatusCode.BadRequest) { Content = new StringContent(body) });
        var (helper, logger) = CreateHelper(handler);
        await Assert.ThrowsAsync<HttpRequestException>(() => helper.GetAsync(NotepadUrl));
        Assert.Contains("空响应正文", Assert.Single(logger.Messages));
    }

    [Fact]
    public async Task Failure_BoundsLogLengthAndRemovesControlCharacters()
    {
        using var handler = new StubHandler(_ => new(HttpStatusCode.BadRequest)
        {
            Content = new StringContent("bad\n\r\u001b" + new string('x', 10000))
        });
        var (helper, logger) = CreateHelper(handler);
        await Assert.ThrowsAsync<HttpRequestException>(() => helper.GetAsync(NotepadUrl));
        string diagnostic = Assert.Single(logger.Messages);
        Assert.Contains("[truncated]", diagnostic);
        Assert.True(diagnostic.Length < 4500);
        Assert.DoesNotContain(diagnostic, char.IsControl);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Success_ReturnsUnchangedBodyAndSendsUnchangedRequest(bool post)
    {
        const string body = """{"data":{"content":"original"},"token":"success-is-not-logged"}""";
        using var handler = new StubHandler(request =>
        {
            Assert.Equal(NotepadUrl, request.RequestUri!.AbsoluteUri);
            Assert.Equal(post ? HttpMethod.Post : HttpMethod.Get, request.Method);
            Assert.Equal("Bearer original-token", request.Headers.Authorization!.ToString());
            return new(HttpStatusCode.OK) { Content = new StringContent(body) };
        });
        var (helper, logger) = CreateHelper(handler);
        var headers = new Dictionary<string, string> { ["Authorization"] = "Bearer original-token" };
        string result = post ? await helper.PostAsync(NotepadUrl, "{}", headers) : await helper.GetAsync(NotepadUrl, headers);

        Assert.Equal(body, result);
        Assert.Empty(logger.Messages);
        Assert.Equal(1, handler.CallCount);
    }

    [Theory]
    [InlineData(200)]
    [InlineData(400)]
    public async Task FormPost_PreservesCookiesAndLogsOnlySanitizedFailures(int status)
    {
        // 本机一次性 HTTP 服务，不请求第三方站点或真实云词本。
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        string url = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/login";
        Task server = RespondAsync();
        using var handler = new StubHandler(_ => throw new InvalidOperationException());
        var (helper, logger) = CreateHelper(handler);
        using var form = new FormUrlEncodedContent(new Dictionary<string, string> { ["password"] = "form-secret" });

        if (status == 200)
        {
            var (response, cookies) = await helper.PostFoRmAsync(url, form, cancellationToken: timeout.Token);
            Assert.Contains("form-secret", response);
            Assert.Equal("cookie-secret", cookies["sid"]);
            Assert.Empty(logger.Messages);
        }
        else
        {
            var exception = await Assert.ThrowsAsync<HttpRequestException>(() => helper.PostFoRmAsync(
                url, form, cancellationToken: timeout.Token));
            Assert.Equal(HttpStatusCode.BadRequest, exception.StatusCode);
            string diagnostic = Assert.Single(logger.Messages) + exception;
            Assert.Contains("invalid login", diagnostic);
            Assert.DoesNotContain("form-secret", diagnostic);
            Assert.DoesNotContain("cookie-secret", diagnostic);
        }
        await server;

        async Task RespondAsync()
        {
            using var client = await listener.AcceptTcpClientAsync(timeout.Token);
            await using var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
            int contentLength = 0;
            while (await reader.ReadLineAsync(timeout.Token) is { Length: > 0 } line)
                if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                    contentLength = int.Parse(line["Content-Length:".Length..].Trim());
            await reader.ReadBlockAsync(new char[contentLength], timeout.Token);
            const string body = "{\"message\":\"invalid login: form-secret\"}";
            string response = $"HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nSet-Cookie: sid=cookie-secret; Path=/\r\nConnection: close\r\n\r\n{body}";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(response), timeout.Token);
        }
    }

    private static (HttpHelper Helper, CapturingLogger Logger) CreateHelper(HttpMessageHandler handler)
    {
        var factory = new Mock<IHttpClientFactory>();
        factory.Setup(value => value.CreateClient(It.IsAny<string>())).Returns(new HttpClient(handler));
        var logger = new CapturingLogger();
        return (new HttpHelper(factory.Object, logger), logger);
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public int CallCount { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++;
            return Task.FromResult(respond(request));
        }
    }

    private sealed class CapturingLogger : ILogger<HttpHelper>
    {
        public List<string> Messages { get; } = [];
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter) => Messages.Add(formatter(state, exception));
    }
}
