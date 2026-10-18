# Design System: DontsTool — Quiet Native
**Project ID:** 17734721049138626585

## 1. Visual Theme & Atmosphere
A compact, keyboard-first native macOS utility, rendered as a floating NSPanel rather than a website. Calm, precise, tactile, translucent graphite material. Content and selection are the visual anchors. Desktop canvas is a subdued abstract graphite wallpaper with gentle ambient texture; no photographs, giant gradients, marketing headlines, charts, account widgets, AI features or decorative dashboards.

## 2. Color Palette & Roles
- Warm graphite #242528: popover background, 94% opaque with restrained backdrop blur.
- Lifted graphite #2E3034: hover and inset controls.
- Hairline silver #FFFFFF1A: separators and top edge highlight.
- Paper white #F3F4F6: primary labels.
- Muted silver #A6A9B0: secondary labels and paths.
- Quiet gray #777C86: tertiary hints; never use for critical small text.
- System blue #458BFF: keyboard selection, focus, active controls; selected row uses #458BFF24 with a thin subtle border.
- Soft green #79C7A5: confirmed copy success only.
- Amber #E7B46E: actionable permission and degradation notices.
Light appearance mapping for eventual Swift implementation: panel #F5F5F7, inset #FFFFFF, text #202124, secondary #6A6D73, selection #E8F0FE, accent #3478F6. Design screens in this project default to dark.

## 3. Typography Rules
Use native system UI typography (-apple-system, BlinkMacSystemFont, SF Pro Text, PingFang SC, sans-serif); Inter is only a fallback token. Simplified Chinese UI, real app/product names remain original. Search 20px regular; row title 14px medium; row subtitle 11px; group caption and footer 11px. Monospaced font for commands, snippets and keyboard symbols. No oversized display headings. Strongly respect native macOS density.

## 4. Component Stylings
- Floating panel: exactly 640 by 420pt for all launcher states, gently rounded 14pt corners, fine translucent border, soft broad shadow; 16pt horizontal insets. No traffic-light window controls on launcher.
- Search: integrated borderless header 60pt tall, magnifier, input and a small shortcut or keyword capsule. Thin divider below.
- Results: 48-52pt rows, 30-32pt icons, left alignment across groups, one primary title, optional middle-truncated path or preview, restrained action on the right. Selected row has softened 8pt corners and subtle system accent fill, clearly visible keyboard focus.
- Compact group labels: 常用 / 工具 / 应用 / 文件; no extra tabs or category rail in the launcher.
- Footer: pinned 32pt area with thin top divider; small product glyph at left and real status text when necessary; inline keycaps ↑↓ 选择, ↵ 执行, esc 关闭 at right. No fake latency or live performance metrics.
- Controls: compact 6-8pt corners; toggle switches and segmented controls reflect native macOS forms. Keyboard keycaps have a fine stroke and inset highlight.
- Settings: separate 820 by 620pt standard native window with macOS traffic lights, 172pt sidebar, grouped forms; only settings has sidebar navigation. Sidebar entries 通用, 搜索, 工具, 翻译, 索引, 关于.
- Toasts: concise, small, nonmodal. Error recovery keeps the panel open.

## 5. Layout Principles
Show a single app window on a 1280 by 900 desktop presentation canvas, positioned horizontally centered and toward the upper middle. Launcher window is always 640 by 420pt. Outside the window leave generous desktop negative space, with no editorial annotations or website chrome. Lists scroll internally when needed; never stretch launcher to a full page. Empty query shows app rows and keyword tool hints. Search shows apps then files then browser fallback only when local matches are absent. Text tools stay in rows with truncated snippets, not a two-pane editor. Translation uses one primary system action and one web fallback, not a chat or paragraph editor. Settings may show planned V1 controls because this is a target design, not a claim that current M1 code implements them.
