#nullable enable
namespace EudicSyncToMaiMemo.Services.Helpers
{
    /// <summary>
    /// 云词库内容与欧路词表增量合并
    /// </summary>
    public static class NotepadWordMergeHelper
    {
        private static readonly string[] LineSeparators = ["\r\n", "\n"];
        public const string StrictChapter = "# 欧路词典同步";

        /// <summary>只接受完整独立收藏；笔记解析出的前缀不获得同步资格。</summary>
        public static TitleCandidate ExtractIndependentTitle(string? word)
        {
            string original = (word ?? "").Trim();
            var candidate = ExtractTitle(original);
            return candidate.Title != null && !string.Equals(candidate.Title, original, StringComparison.Ordinal)
                ? new(null, "non_independent_record") : candidate;
        }

        public sealed class StrictPlan
        {
            public bool Safe { get; set; }
            public string Reason { get; set; } = "ready";
            public string Content { get; set; } = "";
            public List<string> NewTitles { get; set; } = [];
            public int SourceUnique { get; set; }
            public int StoredTitles { get; set; }
            public int Missing { get; set; }
            public int Extra { get; set; }
            public int Duplicates { get; set; }
            public int InvalidLines { get; set; }
            public bool ChapterMode { get; set; }
        }

        /// <summary>只制定追加计划；源外行、重复行或非章节旧词本必须人工处理，绝不自动删除。</summary>
        public static StrictPlan PrepareStrictContent(string content, IReadOnlyList<string> sourceTitles)
        {
            var source = new HashSet<string>(sourceTitles, StringComparer.Ordinal);
            var stored = new HashSet<string>(StringComparer.Ordinal);
            var plan = new StrictPlan { Content = content, SourceUnique = source.Count, ChapterMode = content.StartsWith('#') };
            bool empty = string.IsNullOrWhiteSpace(content);
            foreach (string line in SplitContentLines(content))
            {
                if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#')) continue;
                plan.StoredTitles++;
                if (!stored.Add(line)) plan.Duplicates++;
                var candidate = ExtractIndependentTitle(line);
                if (candidate.Title == null || !string.Equals(candidate.Title, line, StringComparison.Ordinal)) plan.InvalidLines++;
            }
            plan.Missing = source.Except(stored, StringComparer.Ordinal).Count();
            plan.Extra = stored.Except(source, StringComparer.Ordinal).Count();
            plan.Safe = (empty || plan.ChapterMode) && plan.Extra == 0 && plan.Duplicates == 0 && plan.InvalidLines == 0;
            if (!plan.Safe)
            {
                plan.Reason = !empty && !plan.ChapterMode ? "target_not_chapter_mode"
                    : plan.Extra > 0 ? "target_contains_non_source_titles"
                    : plan.Duplicates > 0 ? "target_contains_duplicates" : "target_invalid_lines";
                return plan;
            }
            plan.NewTitles = sourceTitles.Except(stored, StringComparer.Ordinal).ToList();
            if (plan.NewTitles.Count > 0)
                plan.Content = AppendNewTitles(empty ? StrictChapter : content, plan.NewTitles);
            return plan;
        }

        public sealed class TitleCandidate(string? title, string reason)
        {
            public string? Title { get; } = title;
            public string Reason { get; } = reason;
        }

        /// <summary>提取有明确边界的标题；歧义记录不猜测，单条格式异常不影响其他词条。</summary>
        public static TitleCandidate ExtractTitle(string? word)
        {
            try
            {
                var lines = System.Text.RegularExpressions.Regex.Split(word ?? "", @"\r\n|\n|\r");
                string first = lines[0].Trim();
                bool hasNotes = lines.Skip(1).Any(line => !string.IsNullOrWhiteSpace(line));
                var heading = Match(first, @"^#{1,6} (?<title>.+)$");
                string title = heading.Success ? heading.Groups["title"].Value.Trim() : first;
                var definition = Match(title, @"^(?<title>[A-Za-z0-9][A-Za-z0-9 .'\u2019\u2010\u2011-]*?)(?:\s*[:：=]\s*(?:[\u3400-\u9FFF]|(?:meaning|definition)\s*:)|\s+(?:释义|词义|含义|意思|解释)\s*[:：]|\s+是(?:一个|一种)[\u3400-\u9FFF])");
                if (definition.Success) title = definition.Groups["title"].Value.Trim();
                const string token = @"[\p{L}\p{Nd}][\p{L}\p{M}\p{Nd}]*(?:['\u2019\u2010\u2011-][\p{L}\p{Nd}][\p{L}\p{M}\p{Nd}]*)*(?:\.[\p{L}\p{Nd}][\p{L}\p{M}\p{Nd}]*)*\.?";
                bool lexical = Match(title, $@"^{token}(?: +{token})*$").Success
                    && Match(title, @"\p{L}").Success && !Match(title, @"[\u3400-\u9FFF]").Success;
                if (title.Contains(' ') && title.EndsWith('.') && !Match(title, @"(?:^| )(?:\p{L}\.){2,}$").Success)
                    lexical = false;
                if (!lexical || Match(title, @"^(?:学习笔记|笔记|释义|例句|Notes|Examples|Definition)$").Success)
                    return new(null, "unsupported_title");
                bool explicitNotes = Match(string.Join('\n', lines.Skip(1)).TrimStart(),
                    @"^(?:#{1,6} |(?:学习笔记|笔记|释义|例句|Notes|Examples|Definition)[:：])").Success;
                if (hasNotes && !heading.Success && !explicitNotes && !definition.Success)
                    return new(null, "ambiguous_multiline");
                return new(title, hasNotes || heading.Success || definition.Success ? "notes_extracted" : "plain");
            }
            catch (System.Text.RegularExpressions.RegexMatchTimeoutException)
            {
                return new(null, "unsupported_title");
            }
        }

        private static System.Text.RegularExpressions.Match Match(string text, string pattern) =>
            System.Text.RegularExpressions.Regex.Match(text, pattern,
                System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant,
                TimeSpan.FromMilliseconds(250));

        /// <summary>保留完整正文、空行和章节，只在末尾追加新标题。</summary>
        public static string AppendNewTitles(string content, IReadOnlyList<string> newTitles)
        {
            if (newTitles.Count == 0) return content;
            string separator = content.Length > 0 && !content.EndsWith('\n') ? "\n" : "";
            return content + separator + JoinContentLines(newTitles);
        }

        /// <summary>
        /// 去除文本中的控制字符，保留常用排版字符 Tab、CR 和 LF。
        /// 不裁剪空格或规范化 Unicode，避免改变正常词汇、标点、组合字符和 emoji。
        /// </summary>
        public static string RemoveInvalidControlCharacters(string text, out int removedCount)
        {
            var cleaned = new System.Text.StringBuilder(text.Length);
            removedCount = 0;
            foreach (char character in text)
            {
                if (char.IsControl(character) && character is not ('\t' or '\r' or '\n'))
                {
                    removedCount++;
                }
                else
                {
                    cleaned.Append(character);
                }
            }

            return cleaned.ToString();
        }

        /// <summary>
        /// 合并已有行与欧路词表，返回新增词与合并后的行列表
        /// </summary>
        /// <param name="existingLines">云词库现有内容行，含章节行</param>
        /// <param name="eudicWords">欧路生词本单词</param>
        public static (IReadOnlyList<string> NewWords, IReadOnlyList<string> CombinedLines) Merge(
            IReadOnlyList<string> existingLines,
            IReadOnlyList<string> eudicWords)
        {
            var filteredWords = eudicWords.Except(existingLines).ToList();
            var combinedLines = existingLines.Concat(filteredWords).ToList();
            return (filteredWords, combinedLines);
        }

        /// <summary>
        /// 将云词库 content 文本拆分为行
        /// </summary>
        /// <param name="content">云词库原始 content</param>
        public static List<string> SplitContentLines(string content)
        {
            return content.Split(LineSeparators, StringSplitOptions.RemoveEmptyEntries).ToList();
        }

        /// <summary>
        /// 将行列表还原为 content 文本
        /// </summary>
        /// <param name="lines">合并后的行列表</param>
        public static string JoinContentLines(IReadOnlyList<string> lines)
        {
            return string.Join('\n', lines);
        }
    }
}
