$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'diagnose-maimemo.ps1')

$target = 'np-private-test-target'
$credential = 'private-test-token'
$privateContent = 'PRIVATE-NOTEPAD-CONTENT'
$workflowFile = [IO.Path]::GetTempFileName()
$testCount = 0

function Assert-Diagnostic {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function New-TestResponse {
    param([int]$Status = 200, $Payload)
    return @{ Status = $Status; Body = ($Payload | ConvertTo-Json -Depth 20 -Compress) }
}

function Test-Case {
    param([object[]]$Responses, [string]$ExpectedMatch, [int]$ExpectedRequests,
        [int]$ExpectedExit = 1, [string]$Token = $credential, [string]$ExpectedCode = '',
        [int]$ExpectedScanned = -1, [int]$ExpectedPages = -1, [int[]]$ExpectedOffsets = @())
    $state = @{
        Responses = [Collections.Generic.Queue[object]]::new()
        Calls = [Collections.Generic.List[string]]::new()
        Logs = [Collections.Generic.List[string]]::new()
    }
    foreach ($response in $Responses) { $state.Responses.Enqueue($response) }
    $request = {
        param($url, $tokenValue)
        if ($tokenValue -cne $Token) { throw 'Credential was changed' }
        if ($url -cnotmatch '^https://open\.maimemo\.com/open/api/v1/memo/notepads(?:\?limit=10&offset=\d+|/np-private-test-target)$') { throw 'Unexpected request URL' }
        $state.Calls.Add($url)
        if ($state.Responses.Count -eq 0) { throw 'Unexpected additional request' }
        $response = $state.Responses.Dequeue()
        if ($response -is [Exception]) { throw $response }
        return $response
    }.GetNewClosure()
    $writeLog = { param($line) $state.Logs.Add($line) }.GetNewClosure()
    $result = Invoke-MaiMemoReadOnlyDiagnostic -Token $Token -WorkflowPath $workflowFile -Request $request -WriteLog $writeLog
    Assert-Diagnostic ($result -eq $ExpectedExit) "Unexpected result for $ExpectedMatch (exit=$result; $($state.Logs -join '; '))"
    Assert-Diagnostic ($state.Calls.Count -eq $ExpectedRequests) "Unexpected request count for $ExpectedMatch"
    Assert-Diagnostic ($state.Logs.Count -gt 0 -and $state.Logs[-1] -match " target_match=$ExpectedMatch(?: |$)") "Unexpected match result for $ExpectedMatch"
    if ($ExpectedCode) { Assert-Diagnostic ($state.Logs[-1].Contains("error_code=$ExpectedCode ")) 'Unexpected error code' }
    foreach ($line in $state.Logs) {
        Assert-Diagnostic ($line -cmatch '^http_status=\d+ error_code=[a-z0-9_,]+ target_match=[a-z_]+ pages_scanned=\d+ scanned_count=\d+$') 'Unexpected log fields'
        foreach ($secret in @($credential, $target, $privateContent)) {
            Assert-Diagnostic (!$line.Contains($secret)) 'Private information leaked'
        }
    }
    if ($ExpectedScanned -ge 0) {
        Assert-Diagnostic ($state.Logs[-1].EndsWith("scanned_count=$ExpectedScanned")) 'Incorrect scanned count'
    }
    if ($ExpectedPages -ge 0) {
        Assert-Diagnostic ($state.Logs[-1].Contains("pages_scanned=$ExpectedPages ")) 'Incorrect page count'
    }
    if ($ExpectedOffsets.Count -gt 0) {
        $listCalls = @($state.Calls | Where-Object { $_.Contains('?') })
        Assert-Diagnostic ($listCalls.Count -eq $ExpectedOffsets.Count) 'Incorrect list page count'
        for ($index = 0; $index -lt $listCalls.Count; $index++) {
            Assert-Diagnostic ($listCalls[$index].EndsWith("offset=$($ExpectedOffsets[$index])")) 'Pagination did not advance by actual items'
        }
    }
    $script:testCount++
}

function Test-ContentAudit {
    param([object[]]$Responses, [string[]]$ExpectedLines, [int]$ExpectedExit = 0,
        [switch]$LocateLiteralDollarOne, [switch]$TitleAudit)
    $expectedTarget = $target
    $expectedToken = $credential
    $state = @{
        Responses = [Collections.Generic.Queue[object]]::new()
        Calls = [Collections.Generic.List[string]]::new()
        Logs = [Collections.Generic.List[string]]::new()
    }
    foreach ($response in $Responses) { $state.Responses.Enqueue($response) }
    $request = {
        param($url, $authorization)
        if ($url.StartsWith('https://open.maimemo.com/')) {
            if ($url -cne "https://open.maimemo.com/open/api/v1/memo/notepads/$expectedTarget" -or
                $authorization -cne "Bearer $expectedToken") { throw 'Unexpected MaiMemo GET' }
        }
        elseif ($url -cmatch '^https://api\.frdic\.com/api/open/v1/studylist/words\?language=en&category_id=book%20private&page=\d+&page_size=100$') {
            if ($authorization -cne 'NIS private-eudic-token') { throw 'Unexpected Eudic authorization' }
            if (!$url.Contains("page=$($state.Calls.Count - 1)&")) { throw 'Incorrect Eudic page' }
        }
        else { throw 'Unexpected endpoint' }
        $state.Calls.Add($url)
        if ($state.Responses.Count -eq 0) { throw 'Unexpected additional GET' }
        $response = $state.Responses.Dequeue()
        if ($response -is [Exception]) { throw $response }
        return $response
    }.GetNewClosure()
    $writeLog = { param($line) $state.Logs.Add($line) }.GetNewClosure()
    $exitCode = Invoke-MaiMemoContentAudit -Token $credential -EudicAuthorization 'NIS private-eudic-token' -EudicBookId 'book private' -WorkflowPath $workflowFile -Request $request -WriteLog $writeLog -LocateLiteralDollarOne:$LocateLiteralDollarOne -TitleAudit:$TitleAudit
    Assert-Diagnostic ($exitCode -eq $ExpectedExit) "Audit exit mismatch ($exitCode; $($state.Logs -join '; '))"
    Assert-Diagnostic ($state.Calls.Count -eq $Responses.Count) 'Incorrect audit GET count'
    if ($TitleAudit -and $ExpectedExit -eq 0) {
        $skippedLine = @($state.Logs | Where-Object { $_ -match '^source=title_extraction anomaly=skipped ' })
        $skipTotal = [int]([regex]::Match($skippedLine[0], 'count=(\d+)$').Groups[1].Value)
        $classified = 0
        foreach ($line in $state.Logs) {
            if ($line.StartsWith('source=title_skipped ')) { $classified += [int]([regex]::Match($line, 'count=(\d+)$').Groups[1].Value) }
        }
        Assert-Diagnostic ($classified -eq $skipTotal) 'Skip categories must partition the skipped entries'
    }
    foreach ($line in $ExpectedLines) { Assert-Diagnostic ($state.Logs.Contains($line)) "Missing safe audit metric: $line" }
    foreach ($line in $state.Logs) {
        if ($line.StartsWith('source=eudic_word_raw anomaly=literal_dollar_one_entry word_json=')) {
            Assert-Diagnostic ([bool]$LocateLiteralDollarOne) 'Word logging was not enabled'
            Assert-Diagnostic ($ExpectedLines.Contains($line)) 'Unexpected raw entry logged'
            Assert-Diagnostic ($line -notmatch '[\r\n\x00-\x1F\x7F]') 'Unescaped control in entry log'
            foreach ($secret in @($target, $credential, 'private-eudic-token', 'book private', $privateContent)) {
                Assert-Diagnostic (!$line.Contains($secret, [StringComparison]::Ordinal)) 'Entry log leaked a credential or unrelated content'
            }
            continue
        }
        Assert-Diagnostic ($line -cmatch '^source=[a-z_]+ anomaly=[a-z0-9_]+ codepoints=(?:none|U\+[0-9A-F]{4,6}(?:,U\+[0-9A-F]{4,6})*) count=\d+$') 'Unexpected audit output'
        foreach ($secret in @($target, $credential, $privateContent, 'private-eudic-token', 'book private', 'pear', '正常')) {
            Assert-Diagnostic (!$line.Contains($secret, [StringComparison]::Ordinal)) 'Audit output leaked source text'
        }
    }
    $script:testCount++
}

try {
    foreach ($case in @(
        @{ Word = ''; Category = 'empty' },
        @{ Word = "`nword"; Category = 'missing_first_line_title' },
        @{ Word = "word`nother word"; Category = 'ambiguous_multiline'; Reason = 'ambiguous_multiline' },
        @{ Word = "## Notes`nExample."; Category = 'note_heading' },
        @{ Word = '笔记：说明'; Category = 'note_heading' },
        @{ Word = 'at a cost 是一个短语'; Category = 'same_line_definition_candidate'; Proposal = 'definition_boundary_candidate' },
        @{ Word = 'carry with: explanation'; Category = 'same_line_definition_candidate'; Proposal = 'definition_boundary_candidate' },
        @{ Word = '**at a cost**'; Category = 'markdown_or_markup'; Proposal = 'standalone_markdown_candidate' },
        @{ Word = '__carry with__'; Category = 'markdown_or_markup'; Proposal = 'standalone_markdown_candidate' },
        @{ Word = '`apple`'; Category = 'markdown_or_markup'; Proposal = 'standalone_markdown_candidate' },
        @{ Word = '> quoted sentence'; Category = 'markdown_or_markup' },
        @{ Word = 'word (noun)'; Category = 'annotation_or_parentheses' },
        @{ Word = 'word/another'; Category = 'multiple_title_separators' },
        @{ Word = "app`u{200B}le"; Category = 'invisible_or_control' },
        @{ Word = "at`u{00A0}a cost"; Category = 'invisible_or_control' },
        @{ Word = 'U.S.'; Category = 'punctuated_or_alphanumeric_candidate'; Proposal = 'possible_normal_term' },
        @{ Word = 'B2B'; Category = 'punctuated_or_alphanumeric_candidate'; Proposal = 'possible_normal_term' },
        @{ Word = 'word?'; Category = 'symbols_numbers_or_punctuation' },
        @{ Word = '这是一段笔记'; Category = 'non_english_note_candidate' }
    )) {
        $classification = Get-EudicSkippedTitleClassification $case.Word $case.Reason
        $expectedProposal = if ($case.Proposal) { $case.Proposal } else { 'none' }
        Assert-Diagnostic ($classification.Category -ceq $case.Category -and $classification.Proposal -ceq $expectedProposal) 'Unexpected skipped classification'
        $testCount++
    }
    foreach ($case in @(
        @{ Word = 'apple'; Title = 'apple'; Reason = 'plain' },
        @{ Word = 'at a cost'; Title = 'at a cost'; Reason = 'plain' },
        @{ Word = 'carry with'; Title = 'carry with'; Reason = 'plain' },
        @{ Word = 'café'; Title = 'café'; Reason = 'plain' },
        @{ Word = "don't"; Title = "don't"; Reason = 'plain' },
        @{ Word = 'well-known'; Title = 'well-known'; Reason = 'plain' },
        @{ Word = "at a cost`r`n中文学习笔记`nExample costs `$1 million."; Title = 'at a cost'; Reason = 'notes_extracted' },
        @{ Word = "# carry with`n`n释义：中文`nExample sentence."; Title = 'carry with'; Reason = 'notes_extracted' },
        @{ Word = "carry with`n`n笔记：说明`n例句：内容"; Title = 'carry with'; Reason = 'notes_extracted' },
        @{ Word = "carry with`n## Notes`nExamples."; Title = 'carry with'; Reason = 'notes_extracted' },
        @{ Word = "apple`npear"; Title = $null; Reason = 'ambiguous_multiline' },
        @{ Word = "Example sentence`nMore text"; Title = $null; Reason = 'ambiguous_multiline' },
        @{ Word = "carry with`n中文解释但无明确边界"; Title = $null; Reason = 'ambiguous_multiline' },
        @{ Word = '**at a cost**'; Title = $null; Reason = 'unsupported_title' },
        @{ Word = 'at a cost = 中文解释'; Title = $null; Reason = 'unsupported_title' },
        @{ Word = 'at a cost 中文：解释'; Title = $null; Reason = 'unsupported_title' },
        @{ Word = 'Example costs $1 million.'; Title = $null; Reason = 'unsupported_title' },
        @{ Word = '- apple'; Title = $null; Reason = 'unsupported_title' },
        @{ Word = "# Notes`nExample."; Title = $null; Reason = 'unsupported_title' },
        @{ Word = "`napple"; Title = $null; Reason = 'unsupported_title' },
        @{ Word = ''; Title = $null; Reason = 'unsupported_title' },
        @{ Word = "app`u{0011}le"; Title = $null; Reason = 'unsupported_title' }
    )) {
        $candidate = Get-EudicTitleCandidate $case.Word
        Assert-Diagnostic ($candidate.Title -ceq $case.Title -and $candidate.Reason -ceq $case.Reason) 'Unexpected title extraction'
        $testCount++
    }
    [IO.File]::WriteAllText($workflowFile, "env:`n  MaiMemo__DefaultNotepadId: `"$target`"`n")
    $listed = New-TestResponse -Payload @{ success = $true; data = @{ notepads = @(@{ id = $target; content = $privateContent }) } }
    $detail = New-TestResponse -Payload @{ success = $true; data = @{ notepad = @{ id = $target; content = $privateContent } } }
    $empty = New-TestResponse -Payload @{ success = $true; data = @{ notepads = @() } }
    $badId = New-TestResponse -Status 400 -Payload @{ success = $false; errors = @(@{ code = 'common_invalid_res_id'; message = "$target $credential $privateContent" }) }
    Test-Case @($listed, $detail) 'matched_detail_ok' 2 0 -ExpectedScanned 1 -ExpectedPages 1
    Test-Case @($empty, $badId) 'not_found_detail_failed' 2 -ExpectedScanned 0 -ExpectedPages 1 -ExpectedOffsets @(0)
    $shortPage = New-TestResponse -Payload @{ notepads = @(@{ id = 'np-other' }) }
    Test-Case @($shortPage, $empty, $detail) 'not_found_detail_ok' 3 0 -ExpectedScanned 1 -ExpectedPages 2 -ExpectedOffsets @(0, 1)
    Test-Case @($listed, $badId) 'matched_detail_failed' 2 -ExpectedCode 'common_invalid_res_id'
    Test-Case @($badId) 'unknown' 1 -ExpectedCode 'common_invalid_res_id'
    Test-Case @((New-TestResponse -Status 401 -Payload @{ errors = @(@{ code = 'common_invalid_token' }) })) 'unknown_authorization' 1
    Test-Case @(@{ Status = 403; Body = '<html>private-test-token</html>' }) 'unknown_authorization' 1
    Test-Case @((New-TestResponse -Payload @{ success = $false; errors = @(@{ code = 'common_permission_denied' }) })) 'unknown_authorization' 1
    Test-Case @([InvalidOperationException]::new("$credential $target $privateContent")) 'unknown' 1 -ExpectedCode 'transport_error'
    Test-Case @(@{ Status = 200; Body = '<html>private-test-token</html>' }) 'unknown' 1 -ExpectedCode 'non_json_response'
    Test-Case @((New-TestResponse -Payload @{ data = @{} })) 'unknown' 1 -ExpectedCode 'unexpected_list_response'
    Test-Case @((New-TestResponse -Payload @{ notepads = @(@{ content = $privateContent }) })) 'unknown' 1 -ExpectedCode 'unexpected_list_response'
    Test-Case @($listed, (New-TestResponse -Payload @{ notepad = @{ id = 'np-other' } })) 'matched_detail_unknown' 2
    Test-Case @($listed, [InvalidOperationException]::new($credential)) 'matched_detail_unknown' 2
    Test-Case @() 'unknown' 0 -Token '' -ExpectedCode 'configuration_unavailable'
    $fullPage = New-TestResponse -Payload @{ data = @{ notepads = @(0..9 | ForEach-Object { @{ id = "np-other-$_" } }) } }
    Test-Case @($fullPage, $listed, $detail) 'matched_detail_ok' 3 0 -ExpectedScanned 11 -ExpectedPages 2 -ExpectedOffsets @(0, 10)
    Test-Case @($fullPage, $empty, $badId) 'not_found_detail_failed' 3 -ExpectedScanned 10 -ExpectedPages 2 -ExpectedOffsets @(0, 10)
    Test-Case @($shortPage, $listed, $detail) 'matched_detail_ok' 3 0 -ExpectedScanned 2 -ExpectedPages 2 -ExpectedOffsets @(0, 1)
    Test-Case @(1..10 | ForEach-Object { $fullPage }) 'unknown_not_exhausted' 10 -ExpectedCode 'page_limit_reached' -ExpectedScanned 100 -ExpectedPages 10
    Test-Case (@(1..9 | ForEach-Object { $fullPage }) + @($empty, $badId)) 'not_found_detail_failed' 11 -ExpectedScanned 90 -ExpectedPages 10
    Test-Case @((New-TestResponse -Status 400 -Payload @{ errors = @(@{ code = $credential; message = $privateContent }) })) 'unknown' 1 -ExpectedCode 'unavailable'

    $auditNotepad = New-TestResponse -Payload @{ success = $true; data = @{ notepad = @{ id = $target; content = "apple`n# existing`n$privateContent"; title = 'title$1'; brief = ''; tags = @() } } }
    $auditWords = New-TestResponse -Payload @{ data = @(@{ word = 'pear$1'; phon = 'phon$1'; exp = $privateContent }, @{ word = 'pear$1' }, @{ word = 'apple' }) }
    Test-ContentAudit @($auditNotepad, $auditWords) @(
        'source=eudic_word_raw anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=2',
        'source=eudic_phon_ignored anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=1',
        'source=notepad_content_raw anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=0',
        'source=final_content anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=1',
        'source=notepad_title_unchanged anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=1',
        'source=merge anomaly=words_added codepoints=none count=1'
    )
    $plainNotepad = New-TestResponse -Payload @{ success = $true; data = @{ notepad = @{ id = $target; content = "# existing`napple" } } }
    $titleWords = New-TestResponse -Payload @{ data = @(
        @{ word = 'apple' },
        @{ word = "at a cost`n$privateContent costs `$1 million." },
        @{ word = 'at a cost' },
        @{ word = "# carry with`n## Notes`n$privateContent" },
        @{ word = "unknown phrase`n$privateContent" },
        @{ word = '**not a clear title**' }
    ) }
    Test-ContentAudit @($plainNotepad, $titleWords) @(
        'source=title_extraction anomaly=scanned codepoints=none count=6',
        'source=title_extraction anomaly=syncable codepoints=none count=4',
        'source=title_extraction anomaly=skipped codepoints=none count=2',
        'source=title_extraction anomaly=notes_extracted codepoints=none count=2',
        'source=title_extraction anomaly=ambiguous_multiline codepoints=none count=1',
        'source=title_extraction anomaly=unsupported_title codepoints=none count=1',
        'source=title_extraction anomaly=confirmed_at_a_cost codepoints=none count=2',
        'source=title_extraction anomaly=unique_titles codepoints=none count=3',
        'source=title_extraction anomaly=duplicate_titles codepoints=none count=1',
        'source=title_extraction anomaly=already_present codepoints=none count=1',
        'source=title_extraction anomaly=would_add codepoints=none count=2',
        'source=title_skipped anomaly=ambiguous_multiline codepoints=none count=1',
        'source=title_skipped anomaly=markdown_or_markup codepoints=none count=1',
        'source=title_rule_review anomaly=standalone_markdown_candidate codepoints=none count=1',
        'source=extracted_titles anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=0'
    ) -TitleAudit -LocateLiteralDollarOne
    $skippedWords = New-TestResponse -Payload @{ data = @(
        @{ word = 'at a cost：是一个短语' }, @{ word = '**carry with**' }, @{ word = 'U.S.' },
        @{ word = 'B2B' }, @{ word = 'Notes: private details' }, @{ word = 'word/another' },
        @{ word = 'word (noun)' }, @{ word = "app`u{200B}le" }, @{ word = '' },
        @{ word = "word`nother word" }
    ) }
    Test-ContentAudit @($plainNotepad, $skippedWords) @(
        'source=title_extraction anomaly=scanned codepoints=none count=10',
        'source=title_extraction anomaly=syncable codepoints=none count=0',
        'source=title_extraction anomaly=skipped codepoints=none count=10',
        'source=title_skipped anomaly=same_line_definition_candidate codepoints=none count=1',
        'source=title_skipped anomaly=punctuated_or_alphanumeric_candidate codepoints=none count=2',
        'source=title_rule_review anomaly=possible_normal_term codepoints=none count=2',
        'source=title_rule_review anomaly=definition_boundary_candidate codepoints=none count=1',
        'source=title_extraction anomaly=would_add codepoints=none count=0'
    ) -TitleAudit
    $locateWords = New-TestResponse -Payload @{ data = @(
        @{ word = 'cost $1'; exp = $privateContent },
        @{ word = 'normal-private-word'; context_line = 'ignored$1' },
        @{ word = '$1' + "`n" + [char]17 },
        @{ word = '$1 ' + $credential + ' NIS private-eudic-token ' + $target + ' book private' }
    ) }
    Test-ContentAudit @($plainNotepad, $locateWords) @(
        'source=eudic_word_raw anomaly=literal_dollar_one_entry word_json="cost $1"',
        'source=eudic_word_raw anomaly=literal_dollar_one_entry word_json="$1\n\u0011"',
        'source=eudic_word_raw anomaly=literal_dollar_one_entry word_json="$1 [REDACTED] [REDACTED] [REDACTED] [REDACTED]"',
        'source=final_content anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=3'
    ) -LocateLiteralDollarOne
    $controlWord = '$' + [char]17 + '1'
    Test-ContentAudit @($plainNotepad, (New-TestResponse -Payload @{ data = @(@{ word = $controlWord }) })) @(
        'source=eudic_word_raw anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=0',
        'source=eudic_word_raw anomaly=control_candidate codepoints=U+0011 count=1',
        'source=eudic_word_cleaned anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=1',
        'source=final_content anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=1'
    )
    Test-ContentAudit @($plainNotepad, (New-TestResponse -Payload @{ data = @(@{ word = '$' }, @{ word = '1' }, @{ word = "正常`u{200B}`u{00A0}👩‍💻" }) })) @(
        'source=final_content anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=0',
        'source=final_content anomaly=invisible_format_candidate codepoints=U+200B count=1',
        'source=final_content anomaly=invisible_format_candidate codepoints=U+200D count=1',
        'source=final_content anomaly=unicode_space_candidate codepoints=U+00A0 count=1',
        'source=final_content anomaly=symbol_candidate codepoints=U+1F469 count=1'
    )
    $existingLiteral = New-TestResponse -Payload @{ data = @{ notepad = @{ id = $target; content = '# $1' } } }
    Test-ContentAudit @($existingLiteral, (New-TestResponse -Payload @{ data = @() })) @(
        'source=notepad_content_raw anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=1',
        'source=final_content anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=1',
        'source=merge anomaly=words_added codepoints=none count=0'
    )
    $hundredWords = New-TestResponse -Payload @{ data = @(1..100 | ForEach-Object { @{ word = "word$_" } }) }
    Test-ContentAudit @($plainNotepad, $hundredWords, (New-TestResponse -Payload @{ data = @(@{ word = 'last' }) })) @(
        'source=eudic_word_raw anomaly=entries_scanned codepoints=none count=101',
        'source=merge anomaly=words_added codepoints=none count=101'
    )
    $titlePage = New-TestResponse -Payload @{ data = @(1..100 | ForEach-Object { @{ word = 'apple' } }) }
    Test-ContentAudit @($plainNotepad, $titlePage, (New-TestResponse -Payload @{ data = @(@{ word = 'at a cost' }) })) @(
        'source=title_extraction anomaly=scanned codepoints=none count=101',
        'source=title_extraction anomaly=syncable codepoints=none count=101',
        'source=title_extraction anomaly=skipped codepoints=none count=0',
        'source=title_extraction anomaly=would_add codepoints=none count=1'
    ) -TitleAudit
    Test-ContentAudit @((New-TestResponse -Status 401 -Payload @{ errors = @(@{ message = $privateContent }) })) @(
        'source=maimemo_fetch anomaly=http_401 codepoints=none count=1'
    ) -ExpectedExit 1
    Test-ContentAudit @($plainNotepad, (New-TestResponse -Payload @{ data = @(@{ word = $null }) })) @(
        'source=eudic_fetch anomaly=unexpected_response codepoints=none count=1'
    ) -ExpectedExit 1
    Test-ContentAudit @(@{ Status = 200; Body = "$privateContent private-eudic-token <invalid-json>" }) @(
        'source=maimemo_fetch anomaly=unexpected_response codepoints=none count=1'
    ) -ExpectedExit 1
    Test-ContentAudit @($plainNotepad, (New-TestResponse -Status 403 -Payload @{ message = "$privateContent $credential" })) @(
        'source=eudic_fetch anomaly=http_403 codepoints=none count=1'
    ) -ExpectedExit 1
    Test-ContentAudit @($plainNotepad, [InvalidOperationException]::new("$privateContent $credential")) @(
        'source=eudic_fetch anomaly=transport_error codepoints=none count=1'
    ) -ExpectedExit 1

    # 配置解析必须与现有 sync.yml 一致；拒绝多目标/动态表达式，不猜测 ID。
    $actualId = Get-MaiMemoDiagnosticTargetId (Join-Path $PSScriptRoot '../.github/workflows/sync.yml')
    Assert-Diagnostic ($actualId.StartsWith('np-')) 'Existing static target not recognized'
    foreach ($scalar in @("'$target'", $target)) {
        [IO.File]::WriteAllText($workflowFile, "env:`n  MaiMemo__DefaultNotepadId: $scalar # comment`n")
        Assert-Diagnostic ((Get-MaiMemoDiagnosticTargetId $workflowFile) -ceq $target) 'Static scalar changed'
    }
    [IO.File]::WriteAllText($workflowFile, "  MaiMemo__DefaultNotepadId: '$target'`n  MaiMemo__DefaultNotepadId: '$target'`n")
    Test-Case @() 'unknown' 0 -ExpectedCode 'configuration_unavailable'
    [IO.File]::WriteAllText($workflowFile, '  MaiMemo__DefaultNotepadId: ${{ secrets.TEST }}')
    Test-Case @() 'unknown' 0 -ExpectedCode 'configuration_unavailable'
    $workflow = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../.github/workflows/maimemo-diagnostics.yml'))
    Assert-Diagnostic ($workflow.Contains('workflow_dispatch:') -and !$workflow.Contains('Run Sync') -and !$workflow.Contains('dotnet run')) 'Diagnostic workflow can invoke sync'
    Assert-Diagnostic ($workflow.Contains('${{ secrets.MAIMEMO_TOKEN }}')) 'Existing Secret not used'
    Assert-Diagnostic ($workflow.Contains('${{ secrets.EUDIC_AUTHORIZATION }}') -and $workflow.Contains('${{ secrets.EUDIC_BOOK_ID }}')) 'Existing Eudic Secrets not used'

    # 本机 TCP 服务核验真正发出的 HTTP，避免 Mock 掩盖参数/认证头格式问题。
    foreach ($wireCase in @(
        @{ Path = '/open/api/v1/memo/notepads?limit=10&offset=0'; Credential = $credential; Raw = $false; ExpectedAuth = "Bearer $credential" },
        @{ Path = '/api/open/v1/studylist/words?language=en&category_id=book%20private&page=0&page_size=100'; Credential = 'NIS private-eudic-token'; Raw = $true; ExpectedAuth = 'NIS private-eudic-token' }
    )) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $server = [PowerShell]::Create()
    try {
        $port = $listener.LocalEndpoint.Port
        [void]$server.AddScript({
            param($tcpListener)
            $client = $tcpListener.AcceptTcpClientAsync().WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 10000
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                try {
                    $lines = [Collections.Generic.List[string]]::new()
                    do { $line = $reader.ReadLine(); if ($line) { $lines.Add($line) } } while ($line)
                    $body = '{"success":true,"data":{"notepads":[]}}'
                    $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
                    $stream.Write($bytes, 0, $bytes.Length)
                    return $lines -join "`n"
                }
                finally { $reader.Dispose() }
            }
            finally { $client.Dispose() }
        }).AddArgument($listener)
        $pending = $server.BeginInvoke()
        $wireResult = Invoke-MaiMemoDiagnosticGet "http://127.0.0.1:$port$($wireCase.Path)" $wireCase.Credential -RawAuthorization:$wireCase.Raw
        $wireRequest = ($server.EndInvoke($pending)) -join ''
        Assert-Diagnostic ($wireResult.Status -eq 200) 'Loopback HTTP request failed'
        Assert-Diagnostic ($wireRequest.StartsWith("GET $($wireCase.Path) HTTP/1.1")) 'Incorrect wire method or query encoding'
        Assert-Diagnostic ($wireRequest.Contains("Authorization: $($wireCase.ExpectedAuth)")) 'Incorrect wire authorization scheme'
        Assert-Diagnostic ($wireRequest.Contains('Accept: application/json')) 'Incorrect Accept header'
        Assert-Diagnostic ($wireRequest -notmatch '(?im)^Cookie:|^Content-Length: [1-9]') 'Unexpected cookie or request body'
        $testCount++
    }
    finally { $listener.Stop(); $server.Dispose() }
    }
    Write-Host "Read-only diagnostic tests passed: $testCount cases (mock responses and local loopback only)."
}
finally { [IO.File]::Delete($workflowFile) }
