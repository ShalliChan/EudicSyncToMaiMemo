using EudicSyncToMaiMemo.Infrastructure.Exceptions;
using EudicSyncToMaiMemo.Infrastructure.Helpers;
using EudicSyncToMaiMemo.Models.Configuration;
using EudicSyncToMaiMemo.Models.DTOs.MaiMemo.OpenApi;
using EudicSyncToMaiMemo.Services.Helpers;
using EudicSyncToMaiMemo.Services.Interfaces;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace EudicSyncToMaiMemo.Services.Implementations.MaiMemo
{
    /// <summary>
    /// 通过墨墨开放 API 同步云词库
    /// </summary>
    public sealed class MaiMemoOpenApiService(
        IOptions<MaiMemoOptions> maiMemoOptions,
        IHttpHelper httpHelper,
        INotificationService notificationService,
        ILogger<MaiMemoOpenApiService> logger) : IMaiMemoService
    {
        // 官方 api_bundle.yaml：生产 server /open + 云词本路径 /api/v1/memo/notepads。
        private const string ApiBaseUrl = "https://open.maimemo.com/open/api/v1/memo/";
        // 与官方演示的 1..10 范围和官方 CLI 的默认值一致。
        private const int NotepadListPageSize = 10;

        /// <inheritdoc />
        public async Task SyncToMaimemoNotepad(
            string notepadId,
            List<string> eudicWords,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();

            string resolvedNotepadId = await ResolveNotepadIdAsync(notepadId, cancellationToken);

            var notepad = await GetNotepadAsync(resolvedNotepadId, cancellationToken);
            // 严格模式不改写已有正文；异常目标在计划校验中拒绝写入。
            string existingContent = notepad.Content;
            var cleanedWords = new List<string>(eudicWords.Count);
            int incomingRemoved = 0;
            int unsupported = 0, ambiguous = 0, notesExcluded = 0;
            var skippedReasons = new Dictionary<string, int>();
            foreach (string word in eudicWords)
            {
                string cleaned = NotepadWordMergeHelper.RemoveInvalidControlCharacters(word ?? "", out int removed);
                incomingRemoved += removed;
                var candidate = NotepadWordMergeHelper.ExtractIndependentTitle(cleaned);
                if (candidate.Title != null) cleanedWords.Add(candidate.Title);
                else
                {
                    if (candidate.Reason == "non_independent_record") notesExcluded++;
                    else if (candidate.Reason == "ambiguous_multiline") ambiguous++;
                    else unsupported++;
                    string first = cleaned.Split(['\r', '\n'])[0];
                    string reason = candidate.Reason is "ambiguous_multiline" or "non_independent_record" ? candidate.Reason
                        : first.IndexOfAny(['(', ')', '（', '）']) >= 0 ? "annotation_or_parentheses"
                        : first.IndexOfAny(['/', ',', '，', ';', '；']) >= 0 ? "multiple_title_separators"
                        : "unsupported_title";
                    skippedReasons[reason] = skippedReasons.GetValueOrDefault(reason) + 1;
                }
            }
            logger.LogInformation("欧路严格标题：扫描 {Scanned}，独立标题 {Accepted}，无效/歧义 {Invalid}，笔记记录排除 {NotesExcluded}",
                eudicWords.Count, cleanedWords.Count, unsupported + ambiguous, notesExcluded);
            foreach (var skipped in skippedReasons)
                logger.LogWarning("欧路词条跳过：reason={Reason} count={Count}", skipped.Key, skipped.Value);

            if (incomingRemoved > 0)
            {
                logger.LogWarning(
                    "欧路 word 字段控制字符清理数量 {IncomingRemoved}", incomingRemoved);
            }

            var plan = NotepadWordMergeHelper.PrepareStrictContent(existingContent, cleanedWords);
            logger.LogInformation("严格正文校验：源唯一标题 {SourceUnique}，目标行 {Stored}，缺少 {Missing}，源外 {Extra}，重复 {Duplicates}，可更新 {Safe}",
                plan.SourceUnique, plan.StoredTitles, plan.Missing, plan.Extra, plan.Duplicates, plan.Safe);
            if (!plan.Safe) throw new InvalidOperationException($"严格同步拒绝改写目标：{plan.Reason}。请配置新空白词本或通过只读诊断检查目标。");
            var newWords = plan.NewTitles;

            if (newWords.Count > 0)
            {
                notepad.Content = plan.Content;
                await SaveNotepadAsync(resolvedNotepadId, notepad, cancellationToken);
                var stored = await GetNotepadAsync(resolvedNotepadId, cancellationToken);
                var verified = NotepadWordMergeHelper.PrepareStrictContent(stored.Content, cleanedWords);
                if (!verified.Safe || verified.Missing != 0)
                    throw new InvalidOperationException("严格同步写后 GET 校验失败：正文标题集合不一致；未重试。");
                logger.LogInformation("严格同步写后校验通过：正文唯一标题 {Count}", verified.SourceUnique);
                notepad = stored;
            }

            if (notepad.List != null)
            {
                var bodyTitles = new HashSet<string>(NotepadWordMergeHelper.SplitContentLines(notepad.Content), StringComparer.Ordinal);
                int parsedOnly = notepad.List.Where(item => item.Type is "WORD" or "DRAFT_WORD" && item.Word != null)
                    .Select(item => item.Word!).Distinct(StringComparer.Ordinal).Count(word => !bodyTitles.Contains(word));
                if (parsedOnly > 0) logger.LogWarning("墨墨解析层出现正文外表达 {Count} 条；不视为程序新增，不删减正常源标题", parsedOnly);
            }

            await SendNotificationAsync(newWords, cancellationToken);
        }

        private async Task<string> ResolveNotepadIdAsync(string configuredId, CancellationToken cancellationToken)
        {
            if (MaiMemoNotepadIdHelper.IsOpenApiNotepadId(configuredId))
            {
                return configuredId;
            }

            MaiMemoOptions options = maiMemoOptions.Value;
            string? title = options.DefaultNotepadTitle;
            if (string.IsNullOrWhiteSpace(title))
            {
                throw new ConfigurationException(
                    "Open API 模式的 DefaultNotepadId 需为 np- 开头的词库 ID，请通过 GET /api/v1/memo/notepads 获取");
            }

            var notepads = await ListNotepadsAsync(cancellationToken);
            string? resolvedId = MaiMemoNotepadIdHelper.FindIdByTitle(notepads, title);
            if (resolvedId == null)
            {
                throw new ConfigurationException($"未找到标题为「{title}」的云词库，请检查 DefaultNotepadTitle");
            }

            logger.LogInformation(
                "通过标题 {Title} 解析 Open API 云词库 ID：{NotepadId}（配置的 DefaultNotepadId 为网页版数字 ID，已忽略）",
                title,
                resolvedId);

            return resolvedId;
        }

        private async Task<List<BriefNotepadDto>> ListNotepadsAsync(CancellationToken cancellationToken)
        {
            var notepads = new List<BriefNotepadDto>();

            for (int offset = 0; ; offset += NotepadListPageSize)
            {
                cancellationToken.ThrowIfCancellationRequested();

                string url = $"{ApiBaseUrl}notepads?limit={NotepadListPageSize}&offset={offset}";
                string responseJson = await httpHelper.GetAsync(url, CreateAuthHeaders(), cancellationToken);
                var response = JsonHelper.JsonToObj<EnvelopeDto<NotepadListPayloadDto>>(responseJson);
                var page = response?.Data?.Notepads;

                if (page == null || page.Count == 0)
                {
                    break;
                }

                notepads.AddRange(page);

                if (page.Count < NotepadListPageSize)
                {
                    break;
                }
            }

            return notepads;
        }

        private async Task<NotepadDto> GetNotepadAsync(string notepadId, CancellationToken cancellationToken)
        {
            string url = BuildNotepadUrl(notepadId);
            string responseJson = await httpHelper.GetAsync(url, CreateAuthHeaders(), cancellationToken);
            var response = JsonHelper.JsonToObj<EnvelopeDto<NotepadPayloadDto>>(responseJson);

            if (response?.Data?.Notepad == null)
            {
                throw new InvalidOperationException(
                    "获取墨墨云词库失败，响应解析为空。请确认 DefaultNotepadId 为 Open API 的 np- ID。");
            }

            return response.Data.Notepad;
        }

        private async Task SaveNotepadAsync(
            string notepadId,
            NotepadDto notepad,
            CancellationToken cancellationToken)
        {
            string url = BuildNotepadUrl(notepadId);
            var request = new NotepadUpdateRequestDto
            {
                Id = notepadId,
                Notepad = new NotepadUpdateDto
                {
                    Status = notepad.Status,
                    Content = notepad.Content,
                    Title = notepad.Title,
                    Brief = notepad.Brief,
                    Tags = notepad.Tags ?? []
                }
            };
            string requestJson = JsonHelper.ObjToJson(request);
            string responseJson = await httpHelper.PostAsync(url, requestJson, CreateAuthHeaders(), cancellationToken);

            var response = JsonHelper.JsonToObj<EnvelopeDto<NotepadPayloadDto>>(responseJson);
            if (response?.Data?.Notepad == null)
            {
                throw new InvalidOperationException("保存墨墨云词库失败：响应缺少 data.notepad。");
            }
        }

        private static string BuildNotepadUrl(string notepadId)
        {
            return $"{ApiBaseUrl}notepads/{Uri.EscapeDataString(notepadId)}";
        }

        private Dictionary<string, string> CreateAuthHeaders()
        {
            string? token = maiMemoOptions.Value.Token;
            if (string.IsNullOrWhiteSpace(token))
            {
                throw new ConfigurationException("墨墨开放 API Token 为空");
            }

            return new Dictionary<string, string>
            {
                { "Authorization", $"Bearer {token}" },
                { "Accept", "application/json" }
            };
        }

        private async Task SendNotificationAsync(
            IReadOnlyList<string> words,
            CancellationToken cancellationToken)
        {
            if (words.Count > 0)
            {
                string content = string.Join(", ", words);
                logger.LogInformation("新增单词数量 {Total} 条", words.Count);
                await notificationService.SendNotification(content, cancellationToken);
            }
            else
            {
                logger.LogInformation("新增单词数量 0 条");
                await notificationService.SendNotification("没有新增单词", cancellationToken);
            }
        }
    }
}
