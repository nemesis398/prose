package prose_tests

import "core:os"
import "core:strings"
import "core:testing"
import prose "../src"

@(private = "file")
dirs :: proc(t: ^testing.T) -> (cfg, skill: string) {
	root, err := os.make_directory_temp("", "prose-task7w-*", context.allocator)
	testing.expect(t, err == nil)
	cfg, _ = os.join_path({root, "cfg"}, context.allocator)
	skill, _ = os.join_path({root, "skill"}, context.allocator)
	testing.expect(t, os.make_directory(cfg) == nil)
	testing.expect(t, os.make_directory(skill) == nil)
	delete(root)
	return
}

@(private = "file")
dirs_done :: proc(cfg, skill: string) {
	root, _ := os.split_path(cfg)
	root = strings.clone(strings.trim_right(root, "/\\"))
	_ = os.remove_all(root)
	delete(root)
	delete(cfg)
	delete(skill)
}

@(private = "file")
write :: proc(t: ^testing.T, dir, content: string) {
	path, _ := os.join_path({dir, "dictionary.txt"}, context.allocator)
	defer delete(path)
	testing.expect(t, os.write_entire_file_from_string(path, content) == nil)
}

@(private = "file")
has :: proc(ws: prose.Word_Set, word: string) -> bool {
	return prose.word_set_has(ws, word)
}

@(test)
the_builtin_list_is_the_nineteen_words_of_the_reference :: proc(t: ^testing.T) {
	testing.expect_value(t, len(prose.BUILTIN_WORDS), 19)
	cfg, skill := dirs(t)
	defer dirs_done(cfg, skill)
	ws := prose.load_words_in({}, cfg, skill)
	defer prose.word_set_destroy(&ws)
	testing.expect_value(t, len(ws), 19)
	for w in prose.BUILTIN_WORDS {
		testing.expectf(t, has(ws, w), "%s missing", w)
	}
	// Matching is by lowercase, which is how the set stores them.
	testing.expect(t, has(ws, "claude") && has(ws, "CLAUDE") && has(ws, "PostgreSQL"))
	testing.expect(t, "claude" in ws && "languagetool" in ws)
	testing.expect(t, !has(ws, "Zorbax") && !has(ws, ""))
}

@(test)
the_shipped_list_is_read_only_when_the_user_has_none :: proc(t: ^testing.T) {
	cfg, skill := dirs(t)
	defer dirs_done(cfg, skill)
	write(t, skill, "# a comment\n\nShipped\n  Padded  \r\nWith Space\r\n#not-a-word\n")
	{
		ws := prose.load_words_in({}, cfg, skill)
		defer prose.word_set_destroy(&ws)
		testing.expect(t, has(ws, "shipped") && has(ws, "SHIPPED"))
		// Surrounding blanks and a carriage return are trimmed; inner ones stay.
		testing.expect(t, has(ws, "padded") && has(ws, "with space"))
		testing.expect(t, !has(ws, "# a comment") && !has(ws, "#not-a-word") && !has(ws, ""))
		testing.expect_value(t, len(ws), 19 + 3)
	}
	// The user's list replaces the shipped one; it is not added to it.
	write(t, cfg, "Mine\nmine\nÄrger\n")
	{
		ws := prose.load_words_in({}, cfg, skill)
		defer prose.word_set_destroy(&ws)
		testing.expect(t, has(ws, "mine") && has(ws, "MINE") && has(ws, "ärger") && has(ws, "Ärger"))
		testing.expect(t, !has(ws, "shipped"))
		testing.expect_value(t, len(ws), 19 + 2)
	}
	// An empty list of the user's still replaces the shipped one.
	write(t, cfg, "")
	{
		ws := prose.load_words_in({}, cfg, skill)
		defer prose.word_set_destroy(&ws)
		testing.expect(t, !has(ws, "shipped"))
		testing.expect_value(t, len(ws), 19)
	}
}

@(test)
ignore_words_add_to_either_list :: proc(t: ^testing.T) {
	cfg, skill := dirs(t)
	defer dirs_done(cfg, skill)
	write(t, skill, "Shipped\n")
	s := prose.Settings {
		ignore_words = []string{"Zorbax", "Quillnote"},
	}
	{
		ws := prose.load_words_in(s, cfg, skill)
		defer prose.word_set_destroy(&ws)
		testing.expect(t, has(ws, "zorbax") && has(ws, "QUILLNOTE") && has(ws, "shipped"))
		testing.expect_value(t, len(ws), 19 + 3)
	}
	write(t, cfg, "Mine\n")
	{
		ws := prose.load_words_in(s, cfg, skill)
		defer prose.word_set_destroy(&ws)
		testing.expect(t, has(ws, "zorbax") && has(ws, "mine") && !has(ws, "shipped"))
	}
}

@(test)
a_list_that_cannot_be_read_adds_nothing :: proc(t: ^testing.T) {
	cfg, skill := dirs(t)
	defer dirs_done(cfg, skill)
	// Not UTF-8: skipped whole, as the reference skips a file it cannot decode.
	write(t, skill, "Good\n\xff\xfe\nAlso\n")
	ws := prose.load_words_in({}, cfg, skill)
	defer prose.word_set_destroy(&ws)
	testing.expect_value(t, len(ws), 19)
	// A directory where the list should be, and a missing skill directory.
	sub, _ := os.join_path({cfg, "dictionary.txt"}, context.allocator)
	defer delete(sub)
	testing.expect(t, os.make_directory(sub) == nil)
	ws2 := prose.load_words_in({}, cfg, "/nonexistent-prose-skill-dir")
	defer prose.word_set_destroy(&ws2)
	testing.expect_value(t, len(ws2), 19)
}

@(test)
a_byte_order_mark_and_a_huge_line_do_no_harm :: proc(t: ^testing.T) {
	cfg, skill := dirs(t)
	defer dirs_done(cfg, skill)
	huge, _ := strings.repeat("x", 100000, context.allocator)
	defer delete(huge)
	content := strings.concatenate({"\xEF\xBB\xBFFirst\n", huge, "\n"})
	defer delete(content)
	write(t, cfg, content)
	ws := prose.load_words_in({}, cfg, skill)
	defer prose.word_set_destroy(&ws)
	testing.expect(t, has(ws, "first"))
	testing.expect(t, has(ws, huge))
}

@(test)
the_shipped_dictionary_file_adds_no_word :: proc(t: ^testing.T) {
	cfg, unused := dirs(t)
	defer dirs_done(cfg, unused)
	skill := "skills/prose"
	testing.expect(t, os.is_file("skills/prose/dictionary.txt"))
	ws := prose.load_words_in({}, cfg, skill)
	defer prose.word_set_destroy(&ws)
	testing.expect_value(t, len(ws), 19)
}

@(test)
the_skill_directory_is_the_parent_of_the_executables_directory :: proc(t: ^testing.T) {
	d := prose.skill_dir_from_exe_dir("/opt/skills/prose/bin")
	defer delete(d)
	testing.expect_value(t, d, "/opt/skills/prose")
	d2 := prose.skill_dir_from_exe_dir("/opt/skills/prose/bin/")
	defer delete(d2)
	testing.expect_value(t, d2, "/opt/skills/prose")
	d3 := prose.skill_dir_from_exe_dir("")
	defer delete(d3)
	testing.expect_value(t, d3, "")
	p := prose.shipped_dictionary_path("/opt/skills/prose")
	defer delete(p)
	testing.expect_value(t, p, "/opt/skills/prose/dictionary.txt")
}
