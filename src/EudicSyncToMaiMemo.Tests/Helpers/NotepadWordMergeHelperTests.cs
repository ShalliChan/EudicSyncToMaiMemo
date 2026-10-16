using EudicSyncToMaiMemo.Services.Helpers;
using Xunit;

namespace EudicSyncToMaiMemo.Tests.Helpers
{
    /// <summary>
    /// NotepadWordMergeHelper 单元测试
    /// </summary>
    public class NotepadWordMergeHelperTests
    {
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
