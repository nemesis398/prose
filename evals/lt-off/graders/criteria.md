---
type: llm
weight: 1
---

The response:

- says that grammar was not checked, because LanguageTool is off in the
  report (only the mechanical rules ran);
- does not call the text clean, correct or good to publish, and does not say
  the checker found no problems with it as if that settled the matter;
- points at `/prose:setup` (or `prose-check --setup`) to choose a LanguageTool
  backend;
- may point out the grammar errors visible in the text itself (`open` should
  be `opens`, `Their` should be `There`, `runs` should be `run`, `sells`
  should be `sell`), but does not need to.
