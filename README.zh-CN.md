# Claude Plus

[English](README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [العربية](README.ar.md) | 简体中文 | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

你的编码助手不会替你做的两件事，在你不在键盘前的时候完成。

- **保持窗口开着** —— 上一个用量窗口一重置就开一个新的，哪怕没人在干活，这样你回来时已经有一份满额度在跑了。
- **提醒** —— 这件事没做成时会通知你：Bark、ntfy、邮件，或任何你愿意接上的渠道。

撞到用量上限后接着干活，现在这些助手自己就会做；没接上的时候，Claude Plus 替它们接上（见下面的“续跑”）。

## 支持的助手

Claude Code、Codex 和 Antigravity 的计量方式是一样的：一个从你第一个请求开始算的短窗口，外加一个更长周期的额度。你装了哪个，Claude Plus 就替哪个保温。

| 助手 | 额度数据从哪来 | 会改动它的哪些配置 |
|------|----------------|--------------------|
| Claude Code | 它的 status line，每次刷新 | 一条 status line 配置、一个 hook |
| Codex | 它的会话日志，需要时读取 | 不改动任何配置 |
| Antigravity | 它的 status line，每次刷新 | 一条 status line 配置 |

每个助手有各自的窗口、排程和提醒，互不相干。再接一个只需要写一个文件，见 [docs/PROVIDERS.md](docs/PROVIDERS.md)。接口里明确区分了计量方式，因为有的助手不适合保温：Kimi Code 的短窗口限的是请求速率而不是额度，Grok Build 只有一个周池、没有短窗口，这两种情况都没有窗口可以保。

## 为什么有用

**窗口什么时候开，决定它什么时候结束。** 窗口从你的第一个请求开始算，不是固定钟点。以 5 小时窗口为例：9 点上班就开始用，窗口是 9:00-14:00；11 点把额度烧完，就只能干等到 14:00。但如果 6 点已经有个极小的请求把窗口开好了，它 11:00 到期 —— 正好是你额度见底的时刻 —— 新额度已经在那儿等着。窗口一直在转的话，你开始干活时总有一个已经在跑：它剩下的部分是本来会浪费掉的额度，而新的一份最多一个窗口就到，通常早得多。

**窗口开得早，一个工作日能装下更多个。** 9 点上班马上开始用，窗口就是 9:00-14:00 和 14:00-19:00，到下班为止只有两个。如果 6:00 已经自动开好一个，这一天就由 6:00-11:00、11:00-16:00 和 16:00-21:00 覆盖 —— 同样的在座时间，三个额度。下面的固定时刻就是用来钉住这个位置的。

**知道它什么时候帮不上忙了。** 保持窗口开着，只在登录有效、调度器在跑时管用，任何一个出问题就什么都不会发生。Claude Plus 两种情况都认得出来并告诉你，而不是整个周末默默地失败下去。

## 依赖

Linux，并需要 `jq`、`at`（需运行 `atd`）、`flock`、`timeout`、GNU `date`，以及 `claude`、`codex`、`agy` 中至少一个。“续跑”需要 `tmux`。

```bash
sudo systemctl enable --now atd
```

## 安装

```bash
npx @claude-plus/claude-plus
```

或者从源码安装：

```bash
git clone https://github.com/MrJasonZhou/claude-plus.git
cd claude-plus
bash install-claude-plus.sh
```

也可以作为 Claude Code 插件安装，然后在 Claude Code 里运行它的安装程序：

```
/plugin install fluid --marketplace MrJasonZhou/claude-plus
/fluid:install
```

插件叫 `fluid`，因为插件名不能以 `claude-` 开头。“续跑”用的 hook 由插件自带，所以安装脚本不会再把它写进你的配置；另外还有 `/fluid:status`、`/fluid:anchor` 和 `/fluid:uninstall`。

对每个带 status line 的助手，安装脚本会包装你现有的那条（显示和原来完全一样），这是它对该助手配置做的唯一改动（Claude Code 另外多一个 hook，见“续跑”），而且每个配置文件都会先备份。Codex 完全不需要配置。重复执行安装脚本是一次干净的升级，而不是装第二份，并且会保留每个助手下一次排好的任务、它的状态，以及你的通知脚本。

## 使用

日常什么都不用运行 —— 它自己会干活。想看看情况时：

```bash
~/.claude/claude-plus/claude-plus.sh status    # 每个助手：窗口、排程、失败次数
~/.claude/claude-plus/claude-plus.sh providers # 装了哪些助手
tail -f ~/.claude/claude-plus/claude-plus.log  # 它都做了些什么
```

## 在固定时刻开启

默认情况下，上一个窗口一重置就开新的，所以整条链跟着你上次用完额度的时刻走。想把它钉在每天某个时刻：

```bash
~/.claude/claude-plus/claude-plus.sh anchor 06:00   # 每天 06:00 开
~/.claude/claude-plus/claude-plus.sh anchor         # 查看当前设置
~/.claude/claude-plus/claude-plus.sh anchor off     # 恢复成一重置就开
```

会横跨这个时刻的窗口，改成等到那时再开：本来 03:00 要开的窗口覆盖 03:00-08:00，把 06:00 吞掉了，于是推迟到 06:00 开。这样设定时刻之前的那几个小时就没有窗口 —— 如果你那时候在干活，你自己的第一个请求照常会开一个。这个设置对所有助手都生效。

## 保温用的模型

开一个窗口要花掉一次请求，所以 Claude Plus 把它压到最小：用该助手最便宜的模型，不带工具，也不写入历史。模型会更新换代，一旦助手不再认识当前用的这个，它会明确报错 —— Claude Plus 随即改用该助手自己的默认模型并通知你一次，而不是一个窗口一个窗口地失败下去，等人去翻日志。

```bash
~/.claude/claude-plus/claude-plus.sh model                 # 查看每个助手用什么模型保温
~/.claude/claude-plus/claude-plus.sh model claude sonnet   # 自己指定一个
~/.claude/claude-plus/claude-plus.sh model claude auto     # 恢复成最便宜的那个
```

## 续跑

用量上限一重置，Claude Code 会自己把会话接着跑下去（`/config` 里的 "Continue automatically at usage limit"）。但有时它没接上 —— 误按的一个键取消了倒计时，或者倒计时根本没开始 —— 会话就一直停在那儿，直到你发现。Claude Plus 是兜底：它记下每个停在上限上的会话，重置三分钟后再看一眼，如果还停着，就往它的 tmux 窗格里输入 `continue`。

除此之外它不插手。Claude Code 或你已经接着干了、你按 Esc 取消了倒计时、或者那个窗格里已经换成别的程序，它都不会输入任何东西；最多试两次，还不行就通知你。不在 tmux 里的会话没处可输入，只记一笔日志。

## 提醒

Claude Plus 平时不出声，只在需要你处理时才响，而且只报告六件事：

| | |
|---|---|
| **已登出** | 某个助手的登录已过期，在你重新登录之前它什么都开不了 |
| **连续失败** | 某个助手连着几次保温都失败了 |
| **调度停了** | 排好的任务过了很久还没执行，窗口没有被保持开着；通常是 `atd` 没在运行 |
| **恢复正常** | 从上面任一故障中恢复了 |
| **保温模型失效** | 某个助手原本用来保温的模型已经不存在了，之后改用它自己的默认模型 |
| **没能续跑** | 用量上限重置后会话仍然停着，输入 `continue` 也没让它动起来 |

每件事按助手各通报一次，不会每次重试都响，所以过夜出问题只会收到一条消息。自己恢复的故障则一声不响：只有在稍后的重试也失败之后，才会报某个助手已登出。撞到用量上限本身从不通知：那是常态，助手自己会接着干，它们没接上时还有 Claude Plus。

想选择用什么方式收到消息，拷一个示例过去，填上你自己的 key 或服务器：

```bash
cd ~/.claude/claude-plus
cp notify/bark.sh.sample notify.sh      # 也可以是 ntfy.sh.sample、email.sh.sample
chmod +x notify.sh                      # 邮件那个用 700，里面有密码
$EDITOR notify.sh
./claude-plus.sh notify-test            # 确认能收到
```

通知脚本不过是个可执行文件，运行时会拿到 `CP_EVENT`、`CP_MESSAGE`、`CP_HOST`，所以换成 Telegram、Slack、webhook 或 `mail`，无非是改一行。你的这份副本在重新安装后依然保留。

## 文件

全都在 `~/.claude/claude-plus/` 下：

| | |
|---|---|
| `claude-plus.sh` | 脚本本体 |
| `providers/` | 每个助手一个文件 |
| `state/<助手>/` | 该助手的窗口、排程和提醒状态 |
| `notify.sh` | 你配置的通知脚本 |
| `notify/` | 可拷贝的示例 |
| `anchor` | 你设定的窗口开启时刻（如果设了） |
| `claude-plus.log` | 它都做了些什么 |

## 卸载

```bash
npx @claude-plus/claude-plus uninstall
```

或者从源码：`bash install-claude-plus.sh uninstall`。

它会直接在每个助手的配置上修改，只拿掉 Claude Plus 自己加的东西：你原来的 status line 会回来，其他所有设置原样保留 —— 包括安装 Claude Plus 之后才加进去的。它排下的任务会被取消，`~/.claude/claude-plus/` 会被删除，你的 `notify.sh` 也在其中。重复执行不会有任何坏处。

如果之后有别的程序又把某个 status line 包在了 Claude Plus 外面，卸载不会把它弄坏：会留下一个小的透传脚本让那个程序继续工作，卸载时也会告诉你；等不再需要它时再执行一次卸载即可。同样情况下升级，会留在那个程序的链里，而不是反过来把它包起来。

卸载前那一刻每个配置文件都会留一份副本在旁边，安装时留下的副本也都还在，万一需要手动回退可以用。

## 许可证

GPL-3.0-or-later，详见 [LICENSE](LICENSE)。
