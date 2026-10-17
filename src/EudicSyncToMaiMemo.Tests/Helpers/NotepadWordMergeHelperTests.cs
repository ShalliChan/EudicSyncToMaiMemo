using EudicSyncToMaiMemo.Services.Helpers;
using Xunit;

namespace EudicSyncToMaiMemo.Tests.Helpers
{
    /// <summary>
    /// NotepadWordMergeHelper 单元测试
    /// </summary>
    public class NotepadWordMergeHelperTests
    {
        [Theory]
        [InlineData("at a cost", "at a cost")]
        [InlineData("  at a cost  ", "at a cost")]
        [InlineData("U.S.", "U.S.")]
        [InlineData("B2B", "B2B")]
        [InlineData("café", "café")]
        [InlineData("at a cost 是一个常见短语：\nExample costs $1 million.", null)]
        [InlineData("apple\n笔记：说明", null)]
        [InlineData("# at a cost", null)]
        [InlineData("**at a cost**", null)]
        [InlineData("word (noun)", null)]
        [InlineData("word/other", null)]
        [InlineData("word, other", null)]
        [InlineData(null, null)]
        public void IndependentTitles_DoNotDeriveAnything(string? raw, string? expected)
        {
            Assert.Equal(expected, NotepadWordMergeHelper.ExtractIndependentTitle(raw).Title);
        }

        [Fact]
        public void StrictPlan_UsesChapters_PreservesPhrases_AndIsIncremental()
        {
            var initial = NotepadWordMergeHelper.PrepareStrictContent("", ["at a cost", "B2B", "at a cost"]);
            Assert.True(initial.Safe);
            Assert.Equal("# 欧路词典同步\nat a cost\nB2B", initial.Content);
            Assert.Equal(2, initial.NewTitles.Count);
            var again = NotepadWordMergeHelper.PrepareStrictContent(initial.Content, ["at a cost", "B2B"]);
            Assert.True(again.Safe);
            Assert.Equal(0, again.Missing);
            Assert.Empty(again.NewTitles);
            Assert.Equal(initial.Content, again.Content);
            var extended = NotepadWordMergeHelper.PrepareStrictContent(initial.Content, ["at a cost", "B2B", "At a cost"]);
            Assert.Equal(initial.Content + "\nAt a cost", extended.Content); // 精确、区分大小写，不生成或合并变体。
        }

        [Theory]
        [InlineData("apple", "target_not_chapter_mode")]
        [InlineData("//\napple", "target_not_chapter_mode")]
        [InlineData("# old\nold-word", "target_contains_non_source_titles")]
        [InlineData("# old\napple\napple", "target_contains_duplicates")]
        public void StrictPlan_RefusesToRewriteOldOrContaminatedTargets(string existing, string reason)
        {
            var plan = NotepadWordMergeHelper.PrepareStrictContent(existing, ["apple"]);
            Assert.False(plan.Safe);
            Assert.Equal(reason, plan.Reason);
            Assert.Equal(existing, plan.Content);
            Assert.Empty(plan.NewTitles);
        }

        [Fact]
        public void Merge_WithNewWords_ReturnsFilteredAndCombined()
        {
            var existing = new List<string> { "apple", "# chapter" };
            var eudic = new List<string> { "apple", "banana" };

            var (newWords, combined) = NotepadWordMergeHelper.Merge(existing, eudic);

            Assert.Single(newWords);
            Assert.Equal("banana", newWords[0]);
            Assert.Equal(3, combined.Count);
        }

        [Fact]
        public void Merge_WithNoNewWords_ReturnsEmptyNewWords()
        {
            var existing = new List<string> { "apple" };
            var eudic = new List<string> { "apple" };

            var (newWords, combined) = NotepadWordMergeHelper.Merge(existing, eudic);

            Assert.Empty(newWords);
            Assert.Single(combined);
        }

        [Fact]
        public void SplitContentLines_SplitsByNewline()
        {
            var lines = NotepadWordMergeHelper.SplitContentLines("apple\n# chapter\nbanana");

            Assert.Equal(3, lines.Count);
            Assert.Equal("# chapter", lines[1]);
        }

        [Theory]
        [InlineData("app\u0011le", "apple", 1)]
        [InlineData("\0pear\u007f\u0081\u009f", "pear", 4)]
        [InlineData("\u0011\u000b\u000c", "", 3)]
        [InlineData("apple\r\nbanana\n中文\t词条\r", "apple\r\nbanana\n中文\t词条\r", 0)]
        [InlineData("café e\u0301 naïve 中文‘词’—👩‍💻\u200b\u00a0\u2028", "café e\u0301 naïve 中文‘词’—👩‍💻\u200b\u00a0\u2028", 0)]
        [InlineData("literal\\u0011", "literal\\u0011", 0)]
        public void RemoveInvalidControlCharacters_PreservesNormalText(string input, string expected, int expectedRemoved)
        {
            string actual = NotepadWordMergeHelper.RemoveInvalidControlCharacters(input, out int removed);
            Assert.Equal(expected, actual);
            Assert.Equal(expectedRemoved, removed);
        }

        [Fact]
        public void RemoveInvalidControlCharacters_CoversC0AndC1WithoutDeletingUnicode()
        {
            string controls = new(Enumerable.Range(0, 32).Concat(Enumerable.Range(127, 33))
                .Where(code => code is not (9 or 10 or 13)).Select(code => (char)code).ToArray());
            string normal = "English，中文。e\u0301👩‍💻\t\r\n";
            string cleaned = NotepadWordMergeHelper.RemoveInvalidControlCharacters(controls + normal, out int removed);
            Assert.Equal(normal, cleaned);
            Assert.Equal(controls.Length, removed);
            Assert.Equal(cleaned, NotepadWordMergeHelper.RemoveInvalidControlCharacters(cleaned, out int secondRemoved));
            Assert.Equal(0, secondRemoved);
        }
    }
}
