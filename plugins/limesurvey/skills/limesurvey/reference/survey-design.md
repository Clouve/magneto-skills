# Survey design

How to turn what the admin describes into a survey people finish. The file format is in [survey-file-format.md](survey-file-format.md), and a complete example is [example-survey.txt](example-survey.txt).

## Start from what the admin wants to learn

Ask what they will do with the answers. Each question should feed a decision or a number they will report. A question nobody will act on makes the survey longer and the answers to the others worse.

## Keep it short

- Aim for a survey that takes under five minutes: about 10 to 15 questions for most purposes.
- Say how long it takes in the welcome text. People finish what they can see the end of.
- Put the easy, concrete questions first and the open or personal ones last.

## Always write these two texts

- A welcome text (`surveyls_welcometext`): who is asking, why, how long it takes, and what happens with the answers.
- An end text (`surveyls_endtext`): a thank-you, and what happens next if anything.

The checker warns when either is missing.

## Group the questions

A group is a page (with the format `G`). Two to four groups with a clear name each work better than one long page: "About your visit", "Your experience", "Anything else". Don't make a group for one question.

## Choose the type by the answer you need

| You need | Use | Type |
|---|---|---|
| One choice from a short list | List (radio) | `L` |
| One choice from a long list | List (dropdown) | `!` |
| Any number of choices | Multiple choice | `M` |
| Yes or no | Yes/No | `Y` |
| A rating from 1 to 5 | 5 point choice | `5` |
| The same scale for several items | Array | `F` |
| A number | Numerical input, with its lowest and highest value set (the columns `min_num_value_n` and `max_num_value_n`) | `N` |
| A date | Date | `D` |
| A few words | Short free text | `S` |
| A paragraph | Long free text | `T` |
| An order of preference | Ranking | `R` |
| A text between questions, no answer | Text display | `X` |

Prefer closed questions (a list, a scale) where you can name the answers. They take a click, and they can be counted. Keep one or two open questions for what you could not have guessed.

For a list, add "Other" (`other` = `Y`) when your options might not cover everyone. Keep scales the same direction through the whole survey, and label the ends in the help text ("1 is very dissatisfied, 5 is very satisfied").

## Mandatory questions

Make a question mandatory (`mandatory` = `Y`) only when the survey is useless without its answer. Every mandatory question is a place where people give up. Personal details and open questions should almost never be mandatory.

## Show a question only when it applies

A condition goes in the `relevance` column, as an expression over earlier questions' codes:

| Show the question when | relevance |
|---|---|
| always | `1` |
| they answered No to the yes/no question `recommend` | `recommend == "N"` |
| they picked the option `A3` of the list `howheard` | `howheard == "A3"` |
| they ticked the box `SQ002` of the multiple choice `services` | `services_SQ002 == "Y"` |
| the number in `score` is below 7 | `score < 7` |
| either of two things | `recommend == "N" or score < 7` |

A condition can only look at questions that come earlier. The checker warns about a code it does not know or one that comes later.

## Codes

Every question gets a short code: letters and digits, starting with a letter, such as `overall` or `q3reason`. The code is the column heading in exports and the name used in conditions, so make it say what the question is. Answer options get codes too (`A1`, `A2`, or `1` to `5` for a scale). Don't change codes once answers exist.

## Personal data

Ask for a name, an email address or anything else that identifies a person only when the admin needs it, and say in the welcome text why. For feedback that should be anonymous, ask the admin whether to switch on anonymized responses (the `S` row `anonymized` with `Y`). It can't be changed once the survey is active, and answers then can't be tied to a participant.

## One language unless asked

Write the survey in one language. A second language doubles every text row and has to be kept in step for ever after. When the admin asks for more, [survey-file-format.md](survey-file-format.md#more-than-one-language) says how.

## Before you hand it over

Read the survey as someone who has never seen it: is every question clear without the others, does every list have an option for everyone, is anything asked twice? Then import it as a draft and let the admin preview it ([playbooks/draft-a-survey.md](../playbooks/draft-a-survey.md)).
