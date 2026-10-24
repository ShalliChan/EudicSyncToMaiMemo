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
        string? updateJson = null;
        http.Setup(h => h.GetAsync(url, It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), cancellation.Token))
            .ReturnsAsync(() => NotepadResponse(id, updateJson == null ? "# existing\napple\nbanana" : JObject.Parse(updateJson)["notepad"]!["content"]!.Value<string>()!));
        http.Setup(h => h.PostAsync(url, It.IsAny<string>(),
                It.Is<Dictionary<string, string>?>(headers => HasAuth(headers)), cancellation.Token))
            .Callback<string, string, Dictionary<string, string>?, CancellationToken>((_, body, _, _) => updateJson = body)
            .ReturnsAsync(NotepadResponse(id));
        var options = new MaiMemoOptions { Token = "test-token", DefaultNotepadId = id };

        await CreateService(http.Object, options).SyncToMaimemoNotepad(id, ["apple", "banana", "pear"], cancellation.Token);

        var update = JObject.Parse(Assert.IsType<string>(updateJson));
        Assert.Equal(id, update["id"]!.Value<string>());
        var notepad = Assert.IsType<JObject>(update["notepad"]);
        Assert.Equal(new[] { "# existing", "apple", "banana", "pear" },
            notepad["content"]!.Value<string>()!.Split(["\r\n", "\n"], StringSplitOptions.None));
        Assert.Equal("PUBLISHED", notepad["status"]!.Value<string>());
        Assert.Equal("Vocabulary", notepad["title"]!.Value<string>());
        Assert.Equal("Keep this brief", notepad["brief"]!.Value<string>());
        Assert.Equal("original-tag", Assert.Single(notepad["tags"]!).Value<string>());
        Assert.Equal(id, options.DefaultNotepadId);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), cancellation.Token), Times.Exactly(2));
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

        await CreateService(http.Object, options).SyncToMaimemoNotepad("42", ["apple", "banana"], cancellation.Token);

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
    public async Task Sync_FromEudicJson_CleansIncomingControls_AndKeepsStrictNotebookIncremental()
    {
        const string id = "np-test";
        const string unicodeWord = "中文‘词’—naïve👩‍💻";
        string existingContent = "# 保留章节\napple\nkiwi\ncafé";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        const string eudicUrl = "https://api.frdic.com/api/open/v1/studylist/words?language=en&category_id=0&page=0&page_size=100";
        var entries = new[]
        {
            new WordDto { Word = "app\u0011le" },
            new WordDto { Word = "pear\u0011" },
            new WordDto { Word = "pear" },
            new WordDto { Word = "kiwi" },
            new WordDto { Word = "café" },
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

        Assert.Equal("# 保留章节\napple\nkiwi\ncafé\npear\nbanana", sentContent);
        Assert.DoesNotContain(unicodeWord, sentContent!); // 混合笔记/符号不再作为英文词条追加。
        Assert.DoesNotContain(sentContent!, c => char.IsControl(c) && c is not ('\t' or '\r' or '\n'));
        Assert.DoesNotContain("音标", sentContent!);
        Assert.DoesNotContain("释义", sentContent!);
        Assert.DoesNotContain("附加", sentContent!);
        logger.Verify(l => l.Log(LogLevel.Warning, It.IsAny<EventId>(),
            It.Is<It.IsAnyType>((state, _) => state.ToString()!.Contains("word 字段控制字符清理数量 3")
                && !state.ToString()!.Contains("kiwi") && !state.ToString()!.Contains("pear")),
            It.IsAny<Exception?>(), It.IsAny<Func<It.IsAnyType, Exception?, string>>()), Times.Once);

        await service.SyncToMaimemoNotepad(id, rawWords);

        Assert.Equal(new[] { "pear, banana", "没有新增单词" }, notifications);
        http.Verify(h => h.GetAsync(eudicUrl, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.Verify(h => h.GetAsync(notepadUrl, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Exactly(3));
        http.Verify(h => h.PostAsync(notepadUrl, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Sync_WithOnlyDuplicatesOrControlOnlyWords_DoesNotWriteOrClearExistingContent()
    {
        string url = $"{NotepadsUrl}/np-test";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.Setup(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(NotepadResponse("np-test", "# existing\napple"));

        await CreateService(http.Object, new MaiMemoOptions { Token = "test-token", DefaultNotepadId = "np-test" })
            .SyncToMaimemoNotepad("np-test", ["apple", "app\u0011le", "\u0011", "\0", "\t"]);

        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Sync_UsesIndependentTitles_PreservesCompleteNotebook_AndDoesNotRepeatUpdate()
    {
        const string id = "np-test";
        const string original = "# first\r\ncarry with\r\n\r\n# 中文章节\r\ncafé\r\n";
        string saved = original;
        string url = $"{NotepadsUrl}/{id}";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.Setup(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(() => NotepadResponse(id, saved));
        http.Setup(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .Callback<string, string, Dictionary<string, string>?, CancellationToken>((_, json, _, _) =>
            {
                var body = JObject.Parse(json);
                Assert.Equal(id, body["id"]!.Value<string>());
                var notepad = body["notepad"]!;
                saved = notepad["content"]!.Value<string>()!;
                Assert.Equal(original + "at a cost\nU.S.\nB2B", saved);
                Assert.Equal("PUBLISHED", notepad["status"]!.Value<string>());
                Assert.Equal("Vocabulary", notepad["title"]!.Value<string>());
                Assert.Equal("Keep this brief", notepad["brief"]!.Value<string>());
                Assert.Equal("original-tag", Assert.Single(notepad["tags"]!).Value<string>());
                Assert.DoesNotContain("$1", saved);
            })
            .ReturnsAsync(() => NotepadResponse(id, saved));
        List<string> words = ["at a cost 是一个常见短语：\nExample costs $1 million.", "at a cost", "U.S.", "B2B", "carry with", "café",
            "word (noun)", "foo/bar", null!, "Unclear phrase\nSome notes"];
        var originalWords = words.ToArray();
        var service = CreateService(http.Object, new MaiMemoOptions { Token = "test-token", DefaultNotepadId = id });
        await service.SyncToMaimemoNotepad(id, words);
        await service.SyncToMaimemoNotepad(id, words);
        Assert.Equal(originalWords, words); // 不修改欧路源数据。
        http.Verify(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Exactly(3));
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task StrictSync_OldNotebookIsNeverRewritten()
    {
        string url = $"{NotepadsUrl}/np-test";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.Setup(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(NotepadResponse("np-test", "old content"));
        var service = CreateService(http.Object, new MaiMemoOptions { Token = "test-token" });
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => service.SyncToMaimemoNotepad("np-test", ["apple"]));
        Assert.Contains("target_not_chapter_mode", error.Message);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task StrictSync_NewNotebookGetsOnlyIndependentTitles_AndIgnoresParserExpansion()
    {
        const string id = "np-test";
        string url = $"{NotepadsUrl}/{id}";
        string saved = "";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.Setup(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(() => NotepadResponse(id, saved, new[] { new { type = "WORD", word = "boil down" } }));
        http.Setup(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .Callback<string, string, Dictionary<string, string>?, CancellationToken>((_, json, _, _) =>
                saved = JObject.Parse(json)["notepad"]!["content"]!.Value<string>()!)
            .ReturnsAsync(() => NotepadResponse(id, saved));
        var service = CreateService(http.Object, new MaiMemoOptions { Token = "test-token" });
        List<string> raw = ["boil down to", "boil down to", "at a cost 释义：中文\n例句", "**apple**"];
        await service.SyncToMaimemoNotepad(id, raw);
        Assert.Equal("# 欧路词典同步\nboil down to", saved);
        await service.SyncToMaimemoNotepad(id, raw);
        http.Verify(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Exactly(3));
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task StrictSync_ReadbackMismatchFailsWithoutRetry()
    {
        string url = $"{NotepadsUrl}/np-test";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.SetupSequence(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(NotepadResponse("np-test", ""))
            .ReturnsAsync(NotepadResponse("np-test", "# chapter\nwrong"));
        http.Setup(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(NotepadResponse("np-test", "# chapter\nwrong"));
        var service = CreateService(http.Object, new MaiMemoOptions { Token = "test-token" });
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.SyncToMaimemoNotepad("np-test", ["apple"]));
        http.Verify(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Exactly(2));
        http.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task AdditiveSync_RetainsRemovedSourceTitles_AndRepeatedRunDoesNotWrite()
    {
        string url = $"{NotepadsUrl}/np-test";
        string original = "# 第一章\r\napproach\r\nHarvard\r\n\r\n# 第二章\r\npodcast\r\napple";
        string saved = original;
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.Setup(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(() => NotepadResponse("np-test", saved));
        http.Setup(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .Callback<string, string, Dictionary<string, string>?, CancellationToken>((_, json, _, _) =>
                saved = JObject.Parse(json)["notepad"]!["content"]!.Value<string>()!)
            .ReturnsAsync(() => NotepadResponse("np-test", saved));
        var service = CreateService(http.Object, new MaiMemoOptions { Token = "test-token" });
        await service.SyncToMaimemoNotepad("np-test", ["apple", "bits and bobs", "bits and bobs"]);
        Assert.Equal(original + "\nbits and bobs", saved);
        await service.SyncToMaimemoNotepad("np-test", ["apple", "bits and bobs"]);
        http.Verify(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Exactly(3));
        http.VerifyNoOtherCalls();
    }

    [Theory]
    [InlineData("# old\napple\nbanana")]
    [InlineData("# old\napproach\napple\nbanana\nunexpected")]
    public async Task AdditiveSync_RefusesReadbackThatLosesRetainedOrAddsUnexpectedTitles(string readback)
    {
        string url = $"{NotepadsUrl}/np-test";
        var http = new Mock<IHttpHelper>(MockBehavior.Strict);
        http.SetupSequence(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(NotepadResponse("np-test", "# old\napproach\napple"))
            .ReturnsAsync(NotepadResponse("np-test", readback));
        http.Setup(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None))
            .ReturnsAsync(NotepadResponse("np-test", readback));
        var service = CreateService(http.Object, new MaiMemoOptions { Token = "test-token" });
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.SyncToMaimemoNotepad("np-test", ["apple", "banana"]));
        http.Verify(h => h.PostAsync(url, It.IsAny<string>(), It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Once);
        http.Verify(h => h.GetAsync(url, It.IsAny<Dictionary<string, string>?>(), CancellationToken.None), Times.Exactly(2));
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

    private static string NotepadResponse(string id, string content = "# existing\napple\nbanana", object? parsed = null) => JsonConvert.SerializeObject(new
    {
        success = true,
        data = new
        {
            notepad = new
            {
                id, status = "PUBLISHED", content, title = "Vocabulary",
                brief = "Keep this brief", tags = new[] { "original-tag" }, list = parsed
            }
        }
    });
}
