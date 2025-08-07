# File Layout

To support the GUI user experice, we need to seperate user generated content from 11ty config and templates.

- The 11ty root directroy will be `./eleventy/`
- The 11ty includes directory will be `./eleventy/includes/`
- The 11ty input dirctory will be provide by Electron to the CLI as `${app.getPath('userData')}/{$website-name}/`
- The 11ty output dirctory will be provided by Electron to the CLI as `${app.getPath('temp')}/Anglesite//{$website-name}/`

The electron app should support running 11ty through the CLI interface for testing.

By default 11ty should use a "welcome" website as input, which is really just the a custom landing page for the HTML help files, but forfills the "Welcome Screen" requirements for Anglesite. This should be stored at `./docs/` with `index.md` as the welcome root. Then when the user makes a new site, the 11ty process will be restarted with either an empty userData directory named for the site and a sample Markdown file (below), or their chosen themed template files.

```markdown:index.md
---
title: Hello World!
layout: base-layout.njk
---

Change me however you wand and click on the "Publish" button to start your own home on the World Wide Web.

```

By defualt 11ty should continue to use `./dist` as output.
