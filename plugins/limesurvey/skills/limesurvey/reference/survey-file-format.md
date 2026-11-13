# The survey file format

LimeSurvey imports a survey from a tab-separated text file (`.txt` or `.tsv`). It is the easiest format to write by hand. [example-survey.txt](example-survey.txt) is a complete file, and survey-import.sh checks a file before LimeSurvey sees it. LimeSurvey's manual page is <https://www.limesurvey.org/manual/Tab_Separated_Value_survey_structure>.

## The shape

- One row per line. Cells are separated by tabs. The file is UTF-8.
- The first row names the columns. At least these: `id`, `class`, `type/scale`, `name`, `relevance`, `text`, `language`, `mandatory`, `other`. The example also has `related_id`, `help`, `validation`, `default` and `same_default`.
- Any other column in the first row is a setting of the questions: LimeSurvey reads the column's name as a question attribute, and a `Q` row's cell in it as that question's value. The example has two, `min_num_value_n` and `max_num_value_n`, the lowest and the highest number a numerical question takes. Leave the cell empty in rows the setting does not apply to. The checker lets such columns pass and does not know their names, so a misspelt one is ignored by LimeSurvey without a word: use only names from LimeSurvey's manual.
- The `class` column says what a row is.
- Order matters: a group's questions follow its `G` row, and a question's subquestions and answer options follow its `Q` row.
- A text can hold HTML (`<br>`, `<strong>`). It can't hold a tab or a line break.
- No cell may start with a double quote. LimeSurvey reads such a cell as quoted text and can swallow the rest of the row. Start with another character, or write `&quot;`.

## The rows

| class | What it is | id | type/scale | name | text | Other cells |
|---|---|---|---|---|---|---|
| `S` | A survey setting | | | the setting | its value | |
| `SL` | A text of the survey | | | which text | the text | `language` |
| `G` | A group (a page) | a number | its order: 1, 2, 3 | the group's name | a description | `relevance`, `language` |
| `Q` | A question | its own number | the question type | the question's code | the question | `help`, `relevance`, `mandatory`, `other`, `language` |
| `SQ` | A subquestion of the question above | its own number | empty (or `1` for the columns of `:` and `;`) | its code | its text | `relevance`, `language` |
| `A` | An answer option of the question above | the question's number | `0` | its code | its text | `language` |

### S rows: the settings

- `sid`: the survey's id, six digits of your choosing. When that id is taken, LimeSurvey picks another, and survey-import.sh tells you which.
- `language`: the survey's language, such as `en`.
- `format`: `G` shows one group per page, `S` one question per page, `A` everything on one page.
- `anonymized`: `Y` makes answers impossible to tie to a participant. It can't be changed once the survey is active.
- A survey is always imported inactive. An `S` row for `active` is ignored.

### SL rows: the texts

`surveyls_title` (needed), `surveyls_description`, `surveyls_welcometext` and `surveyls_endtext`. Each needs the language in the `language` column.

### Q rows: the questions

The question types, with what each needs below its `Q` row:

| Type | Question | Needs |
|---|---|---|
| `S` | Short free text | |
| `T` | Long free text | |
| `U` | Huge free text | |
| `N` | Numerical input | |
| `D` | Date | |
| `Y` | Yes/No | |
| `G` | Gender | |
| `5` | 5 point choice | |
| `X` | Text display (no answer) | |
| `L` | List (radio) | `A` rows |
| `!` | List (dropdown) | `A` rows |
| `O` | List with comment | `A` rows |
| `M` | Multiple choice | `SQ` rows |
| `P` | Multiple choice with comments | `SQ` rows |
| `Q` | Multiple short text | `SQ` rows |
| `K` | Multiple numerical input | `SQ` rows |
| `R` | Ranking | `SQ` rows (the items to rank) |
| `A`, `B`, `C`, `E` | Array with a fixed scale (5 point, 10 point, yes/uncertain/no, increase/same/decrease) | `SQ` rows (the lines) |
| `F` | Array with your own scale | `SQ` rows (the lines) and `A` rows (the scale) |
| `H` | Array by column | `SQ` rows and `A` rows |
| `1` | Array dual scale | `SQ` rows, `A` rows with `0`, and `A` rows with `1` in type/scale |
| `:`, `;` | Array of numbers, array of texts | `SQ` rows for the lines, and `SQ` rows with `1` in type/scale for the columns |
| `|` | File upload | |
| `*` | Equation | |

- `name` is the question's code: it starts with a letter and holds only letters and digits, 20 at most. Each code is used once in the survey.
- `mandatory` is `Y`, `N`, or `S` (asked for, but can be skipped).
- `other` is `Y` to add an "Other" option with a text box. Only `L`, `!`, `M` and `P` have one.
- `relevance` is `1` for "always", or a condition ([survey-design.md](survey-design.md#show-a-question-only-when-it-applies)).

### SQ and A rows

- A subquestion needs a number of its own in the `id` column, one that no other `Q` or `SQ` row has. Without it LimeSurvey drops the subquestion and says nothing (tested on 7.10.0: a file whose two subquestions carried their question's id came in with none).
- An answer option's code is 1 to 5 letters and digits. A subquestion's code is letters and digits, such as `SQ001`.
- In a ranking question the items are `SQ` rows. LimeSurvey 7 stores them as subquestions.

## What the checker refuses

survey-import.sh stops, with the line number, when:

- the header lacks a needed column, a row has more cells than the header, or a cell starts with a double quote;
- there is no `S` row for `sid` or for `language`, or no `surveyls_title`;
- there is no group or no question, or a question comes before the first group;
- a question's type is unknown, its code is not letters and digits, or its code is used twice in one language;
- a translation has another type than the question it translates;
- a `Q` or `SQ` row has no number in `id`, or one that another row has;
- an `A` row sits under a question that takes none, or an `SQ` row under one that takes none;
- a question that needs answer options or subquestions has none.

It warns, and still imports, when a welcome or end text is missing, a question has no text, a condition names a code that is not in the file or comes later, the survey has more than one language, or a language has another number of groups, subquestions or answer options than the base language.

After the import it compares LimeSurvey's counts of groups, questions, subquestions and answer options with the file's.

## Check and import

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-import.sh --check-only <survey file>
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-import.sh <survey file>
```

## More than one language

Add an `S` row `additional_languages` with the other language codes, separated by spaces. Then every `SL`, `G`, `Q`, `SQ` and `A` row appears once per language, with the same `id`, code and type, the translated text, and its language in the `language` column. The checker warns that the survey has more than one language, so that it is a choice and not an accident.

How LimeSurvey ties the rows of the languages together, which is also what the checker follows:

- A `G` row is the same group as the group at the same position in the base language: the first `G` row of each language, the second, and so on. So every language has the same groups in the same order.
- A `Q` row whose code is already a question of that group is that question's text in another language. It is not a second question. It keeps the question's type.
- An `SQ` or `A` row belongs to the question of the last `Q` row above it, and each code appears once per language.

So the order of the rows is yours to choose. Write each row followed by its translation, as here, or a question with all its rows in one language and then again in the next, or the whole file in one language and then again in the next. All three import as the same survey. The first keeps a text and its translation side by side, which is the easiest to check.

```text
1	G	1	About you	1		en
1	G	1	Über Sie	1		de
1	Q	L	heard	1	How did you hear about us?	en
1	Q	L	heard	1	Wie haben Sie von uns erfahren?	de
1	A	0	A1		From a friend	en
1	A	0	A1		Von Bekannten	de
```

The six rows show the columns `id`, `class`, `type/scale`, `name`, `relevance`, `text` and `language`, and leave the others out. Don't give the second language codes of its own: `A1` in `en` and `A1` in `de` are the same answer option, and two codes would make two options.

## The other formats

- `.lss` is LimeSurvey's own XML export of a survey's structure. It carries everything, and it is best made by exporting, not by hand. survey-import.sh and survey-archive.sh import it as an inactive draft.
- `.lsa` is an archive of a survey with its answers and participants. LimeSurvey activates a survey it imports from one ([playbooks/copy-or-move-a-survey.md](../playbooks/copy-or-move-a-survey.md)).
