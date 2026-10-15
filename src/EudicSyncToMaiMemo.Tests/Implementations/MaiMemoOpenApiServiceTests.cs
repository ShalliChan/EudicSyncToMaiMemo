using System.Net;
using EudicSyncToMaiMemo.Infrastructure.Helpers;
using EudicSyncToMaiMemo.Models.Configuration;
using EudicSyncToMaiMemo.Services.Implementations.MaiMemo;
using EudicSyncToMaiMemo.Services.Interfaces;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Moq;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Xunit;

namespace EudicSyncToMaiMemo.Tests.Implementations;

public class MaiMemoOpenApiServiceTests
{
    // 期望 URL 独立于实现中的常量，防止列表/详情/更新回退到旧路由。
    private const string NotepadsUrl = "https://open.maimemo.com/open/api/v1/memo/notepads";

    [Theory]
    [InlineData("np-test")]
    [InlineData("np-test/with space")]
    public async Task Sync_UsesOfficialDetailAndUpdatePaths_AndPreservesExistingContent(string id)
    {
        string url = $"{NotepadsUrl}/{Uri.EscapeDataString(id)}";
        using var cancellation = new CancellationTokenSource();
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.Setup(h => h.GetAsync(url, It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), cancellation.Token))
            .ReturnsAsync(NotepadResponse(id));
        string? updateJson = null;
        http.Setup(h => h.PostAsync(url, It.IsAny<string>(),
                It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), cancellation.Token))
            .Callback<string, string, Dictionary<string, string>?, CancellationToken>((_, body, _, _) => updateJson = body)
            .ReturnsAsync(NotepadResponse(id));
        var options = new MaiMemoOptions { Token = "test-token", DefaultNotepadId = id };

        await CreateService(http.Object, options).SyncToMaimemoNotepad(id, ["banana", "pear"], cancellation.Token);

        var update = JObject.Parse(Assert.IsType<string>(updateJson));
        var notepad = Assert.IsType<JObject>(update["notepad"]);
        Assert.Equal(new[] { "apple", "banana", "pear" },
            notepad["content"]!.Value<string>()!.Split(["\r\n", "\n"], StringSplitOptions.None));
        Assert.Equal("PUBLISHED", notepad["status"]!.Value<string>());
        Assert.Equal("Vocabulary", notepad["title"]!.Value<string>());
        Assert.Equal("Keep this brief", notepad["brief"]!.Value<string>());
        Assert.Equal("original-tag", Assert.Single(notepad["tags"]!).Value<string>());
        Assert.Equal(id, options.DefaultNotepadId);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), cancellation.Token), Times.Once);
        http.Verify(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), cancellation.Token), Times.Once);
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Sync_ByTitle_UsesOfficialListPathForEveryPage_AndSkipsUnneededUpdate()
    {
        using var cancellation = new CancellationTokenSource();
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        var firstPage = Enumerable.Range(0, 100)
            .Select(index => new { id = $"np-other-{index}", title = $"Other {index}" }).ToArray();
        string[] listUrls = [$"{NotepadsUrl}?limit=100&offset=0", $"{NotepadsUrl}?limit=100&offset=100"];
        http.Setup(h => h.GetAsync(listUrls[0], It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), cancellation.Token))
            .ReturnsAsync(JsonConvert.SerializeObject(new { success = true, data = new { notepads = firstPage } }));
        http.Setup(h => h.GetAsync(listUrls[1], It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), cancellation.Token))
            .ReturnsAsync("""{"success":true,"data":{"notepads":[{"id":"np-test","title":"Vocabulary"}]}}""");
        string detailUrl = $"{NotepadsUrl}/np-test";
        http.Setup(h => h.GetAsync(detailUrl, It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), cancellation.Token))
            .ReturnsAsync(NotepadResponse("np-test"));
        var options = new MaiMemoOptions
        {
            Token = "test-token", DefaultNotepadId = "42", DefaultNotepadTitle = "Vocabulary"
        };

        await CreateService(http.Object, options).SyncToMaimemoNotepad("42", ["apple"], cancellation.Token);

        Assert.Equal("42", options.DefaultNotepadId);
        foreach (string url in listUrls.Append(detailUrl))
            http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), cancellation.Token), Times.Once);
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Sync_WhenDetailFails_DoesNotRetryOrWrite()
    {
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        var failure = new HttpRequestException("Invalid resource id", null, HttpStatusCode.BadRequest);
        http.Setup(h => h.GetAsync($"{NotepadsUrl}/np-test", It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ThrowsAsync(failure);

        var exception = await Assert.ThrowsAsync<HttpRequestException>(() => CreateService(http.Object,
            new MaiMemoOptions { Token = "test-token", DefaultNotepadId = "np-test" })
            .SyncToMaimemoNotepad("np-test", ["pear"]));

        Assert.Same(failure, exception);
        http.Verify(h => h.GetAsync($"{NotepadsUrl}/np-test", It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.VerifyNoOtherCalls();
    }

    private static bool HasAuth(Dictionary<string, string>? headers) =>
        headers != null && headers.GetValueOrDefault("Authorization") == "Bearer test-token"
        && headers.GetValueOrDefault("Accept") == "application/json";

    private static MaiMemoOpenApiService CreateService(IHttpHelper http, MaiMemoOptions options)
    {
        var notification = new Mock<INotificationService>();
        notification.Setup(n => n.SendNotification(It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .Returns(Task.CompletedTask);
        return new MaiMemoOpenApiService(Options.Create(options), http, notification.Object,
            NullLogger<MaiMemoOpenApiService>.Instance);
    }

    private static string NotepadResponse(string id) => JsonConvert.SerializeObject(new
    {
        success = true,
        data = new
        {
            notepad = new
            {
                id, status = "PUBLISHED", content = "apple\nbanana", title = "Vocabulary",
                brief = "Keep this brief", tags = new[] { "original-tag" }
            }
        }
    });
}
