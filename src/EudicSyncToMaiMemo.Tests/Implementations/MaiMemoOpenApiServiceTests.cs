using System.Net;
using EudicSyncToMaiMemo.Infrastructure.Helpers;
using EudicSyncToMaiMemo.Models.Configuration;
using EudicSyncToMaiMemo.Models.DTOs.Eudic;
using EudicSyncToMaiMemo.Services.Implementations;
using EudicSyncToMaiMemo.Services.Implementations.MaiMemo;
using EudicSyncToMaiMemo.Services.Interfaces;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Logging;
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
        var firstPage = Enumerable.Range(0, 10)
            .Select(index => new { id = $"np-other-{index}", title = $"Other {index}" }).ToArray();
        string[] listUrls = [$"{NotepadsUrl}?limit=10&offset=0", $"{NotepadsUrl}?limit=10&offset=10"];
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

    [Fact]
    public async Task Sync_FromEudicJson_CleansBothSourcesBeforeDeduplication_AndIsIncremental()
    {
        const string id = "np-test";
        const string unicodeWord = "中文‘词’—naïve👩‍💻";
        string existingContent = "apple\napple\n# 保留章节\nki\u0011wi\ncafé";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        const string eudicUrl = "https://api.frdic.com/api/open/v1/studylist/words?language=en&category_id=0&page=0&page_size=100";
        var entries = new[]
        {
            new WordDto { Word = "app\u0011le" },
            new WordDto { Word = "pear\u0011" },
            new WordDto { Word = "pear" },
            new WordDto { Word = unicodeWord },
            new WordDto { Word = "\u0011" },
            new WordDto { Word = "banana", Phon = "音标\u0011", Exp = "释义\u0011", ContextLine = "附加\u0011" }
        };
        http.Setup(h => h.GetAsync(eudicUrl, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(JsonConvert.SerializeObject(new { data = entries }));
        string notepadUrl = $"{NotepadsUrl}/{id}";
        http.Setup(h => h.GetAsync(notepadUrl, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(() => NotepadResponse(id, existingContent));
        string? sentContent = null;
        http.Setup(h => h.PostAsync(notepadUrl, It.IsAny<string>(),
                It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), CancellationToken.None))
            .Callback<string, string, Dictionary<string, string>?, CancellationToken>((_, json, _, _) =>
            {
                var payload = JObject.Parse(json)["notepad"]!;
                sentContent = payload["content"]!.Value<string>();
                Assert.Equal("Vocabulary", payload["title"]!.Value<string>());
                Assert.Equal("Keep this brief", payload["brief"]!.Value<string>());
                existingContent = sentContent!; // 模拟服务器保存后的下一次读取，不访问真实 API。
            })
            .ReturnsAsync(() => NotepadResponse(id, existingContent));
        var eudic = new EudicService(Options.Create(new EudicOptions { Authorization = "NIS test" }),
            http.Object, NullLogger<EudicService>.Instance);
        var rawWords = await eudic.GetWords("0");
        Assert.Contains("app\u0011le", rawWords); // JSON 解码保留控制字符，清理位于墨墨提交边界。
        var notifications = new List<string>();
        var notification = new Mock<INotificationService>();
        notification.Setup(n => n.SendNotification(It.IsAny<string>(), CancellationToken.None))
            .Callback<string, CancellationToken>((text, _) => notifications.Add(text))
            .Returns(Task.CompletedTask);
        var logger = new Mock<ILogger<MaiMemoOpenApiService>>();
        var service = new MaiMemoOpenApiService(
            Options.Create(new MaiMemoOptions { Token = "test-token", DefaultNotepadId = id }),
            http.Object, notification.Object, logger.Object);

        await service.SyncToMaimemoNotepad(id, rawWords);

        Assert.Equal($"apple\napple\n# 保留章节\nkiwi\ncafé\npear\n{unicodeWord}\nbanana", sentContent);
        Assert.DoesNotContain(sentContent!, c => char.IsControl(c) && c is not ('\t' or '\r' or '\n'));
        Assert.DoesNotContain("音标", sentContent!);
        Assert.DoesNotContain("释义", sentContent!);
        Assert.DoesNotContain("附加", sentContent!);
        logger.Verify(l => l.Log(LogLevel.Warning, It.IsAny<EventId>(),
            It.Is<It.IsAnyType>((state, _) => state.ToString()!.Contains("word 字段 3 个")
                && state.ToString()!.Contains("content 字段 1 个")
                && !state.ToString()!.Contains("kiwi") && !state.ToString()!.Contains("pear")),
            It.IsAny<Exception?>(), It.IsAny<Func<It.IsAnyType, Exception?, string>>()), Times.Once);

        await service.SyncToMaimemoNotepad(id, rawWords);

        Assert.Equal(new[] { $"pear, {unicodeWord}, banana", "没有新增单词" }, notifications);
        http.Verify(h => h.GetAsync(eudicUrl, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.Verify(h => h.GetAsync(notepadUrl, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Exactly(2));
        http.Verify(h => h.PostAsync(notepadUrl, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Sync_WithOnlyDuplicatesOrControlOnlyWords_DoesNotWriteOrClearExistingContent()
    {
        string url = $"{NotepadsUrl}/np-test";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.Setup(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(NotepadResponse("np-test", "app\u0011le\n# existing"));

        await CreateService(http.Object, new MaiMemoOptions { Token = "test-token", DefaultNotepadId = "np-test" })
            .SyncToMaimemoNotepad("np-test", ["apple", "app\u0011le", "\u0011", "\0", "\t"]);

        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
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

    private static string NotepadResponse(string id, string content = "apple\nbanana") => JsonConvert.SerializeObject(new
    {
        success = true,
        data = new
        {
            notepad = new
            {
                id, status = "PUBLISHED", content, title = "Vocabulary",
                brief = "Keep this brief", tags = new[] { "original-tag" }
            }
        }
    });
}
