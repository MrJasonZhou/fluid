# Fluid

[English](README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [العربية](README.ar.md) | [简体中文](README.zh-CN.md) | 繁體中文 | [日本語](README.ja.md)

你的編碼助手不會替你做的兩件事，在你不在鍵盤前的時候完成。

- **讓視窗一直開著** —— 上一個用量視窗一重設就開一個新的，就算沒人在做事也一樣，這樣你回來時已經有一份滿額度在跑了。
- **提醒** —— 這件事沒做成時會通知你：Bark、ntfy、郵件，或任何你願意接上的管道。

撞到用量上限後接著做事，現在這些助手自己就會處理；沒接上的時候，Fluid 替它們接上（見下面的「續跑」）。

## 支援的助手

Claude Code、Codex 和 Antigravity 的計量方式是一樣的：一個從你第一個請求開始算的短視窗，外加一個更長週期的額度。你裝了哪個，Fluid 就替哪個保溫。

| 助手 | 額度資料從哪來 | 會改動它的哪些設定 |
|------|----------------|--------------------|
| Claude Code | Fluid 外掛的 hooks 模組，用量變化時 | 無 |
| Codex | 它的工作階段日誌，需要時讀取 | 不改動任何設定 |
| Antigravity | 它的 status line，每次更新 | 一條 status line 設定 |

每個助手有各自的視窗、排程和提醒，互不相干。再接一個只需要寫一個檔案，見 [docs/PROVIDERS.md](docs/PROVIDERS.md)。介面裡明確區分了計量方式，因為有的助手不適合保溫：Kimi Code 的短視窗限的是請求速率而不是額度，Grok Build 只有一個週池、沒有短視窗，這兩種情況都沒有視窗可以保。

## 為什麼有用

**視窗什麼時候開，決定它什麼時候結束。** 視窗從你的第一個請求開始算，不是固定鐘點。以 5 小時視窗為例：9 點上班就開始用，視窗是 9:00-14:00；11 點把額度燒完，就只能乾等到 14:00。但如果 6 點已經有個極小的請求把視窗開好了，它 11:00 到期 —— 正好是你額度見底的時刻 —— 新額度已經在那裡等著。視窗一直在轉的話，你開始做事時總有一個已經在跑：它剩下的部分是本來會浪費掉的額度，而新的一份最多一個視窗就到，通常早得多。

**視窗開得早，一個工作日能裝下更多個。** 9 點上班馬上開始用，視窗就是 9:00-14:00 和 14:00-19:00，到下班為止只有兩個。如果 6:00 已經自動開好一個，這一天就由 6:00-11:00、11:00-16:00 和 16:00-21:00 涵蓋 —— 同樣的在座時間，三個額度。下面的固定時刻就是用來釘住這個位置的。

**知道它什麼時候幫不上忙了。** 讓視窗一直開著，只在登入有效、排程器在跑時管用，任何一個出問題就什麼都不會發生。Fluid 兩種情況都認得出來並告訴你，而不是整個週末默默地失敗下去。

## 相依套件

Linux 或 macOS，需要 `jq`，以及 `claude`、`codex`、`agy` 中至少一個。Claude Code 請以外掛方式安裝 Fluid（見下文）：它的用量讀取和「續跑」都來自外掛的 hooks 模組。Linux 上用 `at` 排定工作，所以 `atd` 要在執行；macOS 上交給 launchd，不用任何設定。Windows 上請在啟用了 systemd 的 WSL 裡執行 Claude Code，這樣 atd 才能啟動。

```bash
sudo systemctl enable --now atd   # Linux
brew install jq                   # macOS
```

## 安裝

```bash
npx fluid-agents
```

或者從原始碼安裝：

```bash
git clone https://github.com/MrJasonZhou/fluid.git
cd fluid
bash install-fluid.sh
```

也可以作為 Claude Code 外掛安裝，然後在 Claude Code 裡執行它的安裝程式：

```
/plugin install fluid --marketplace MrJasonZhou/fluid
/fluid:install
```

外掛提供 `/fluid:status`、`/fluid:anchor` 和 `/fluid:uninstall`，還帶一個在 Claude Code 內部執行的 hooks 模組：它把用量讀數交給 Fluid，並續跑停下的工作階段（見「續跑」），完全不改 Claude Code 的設定。hooks 模組仍在按帳號逐步開放。模組沒有載入、或者沒裝外掛時，Claude Code 的視窗照樣會保持開啟，只是只能按估算的重置時間來排，安裝指令碼會提示這一點。用 `/fluid:status` 可以看到讀數來自哪裡。

對 Antigravity，安裝指令碼會包裝你現有的 status line（顯示和原來完全一樣），這是它對其設定做的唯一改動，而且每個設定檔都會先備份。Codex 和 Claude Code 完全不需要設定。重複執行安裝指令碼是一次乾淨的升級，而不是裝第二份，並且會保留每個助手下一次排好的工作、它的狀態，以及你的通知指令碼。0.3.0 之前的版本還會包裝 Claude Code 的 status line，並在它的設定裡加一個 hook：裝外掛前先解除安裝一次（見下文），這兩項就會被移除。

## 使用

日常什麼都不用執行 —— 它自己會做事。想看看情況時：

```bash
~/.fluid/fluid.sh status    # 每個助手：視窗、排程、失敗次數
~/.fluid/fluid.sh providers # 裝了哪些助手
tail -f ~/.fluid/fluid.log  # 它都做了些什麼
```

## 在固定時刻開啟

預設情況下，上一個視窗一重設就開新的，所以整條鏈跟著你上次用完額度的時刻走。想把它釘在每天某個時刻：

```bash
~/.fluid/fluid.sh anchor 06:00   # 每天 06:00 開
~/.fluid/fluid.sh anchor         # 查看目前設定
~/.fluid/fluid.sh anchor off     # 恢復成一重設就開
```

會橫跨這個時刻的視窗，改成等到那時再開：本來 03:00 要開的視窗覆蓋 03:00-08:00，把 06:00 吞掉了，於是推遲到 06:00 開。這樣設定時刻之前的那幾個小時就沒有視窗 —— 如果你那時候在做事，你自己的第一個請求照常會開一個。這個設定對所有助手都生效。

## 保溫用的模型

開一個視窗要花掉一次請求，所以 Fluid 把它壓到最小：用該助手最便宜的模型，不帶工具，也不寫入歷史。模型會改朝換代，一旦助手不再認得目前用的這個，它會明確報錯 —— Fluid 隨即改用該助手自己的預設模型並通知你一次，而不是一個視窗一個視窗地失敗下去，等人去翻紀錄。

```bash
~/.fluid/fluid.sh model                 # 查看每個助手用什麼模型保溫
~/.fluid/fluid.sh model claude sonnet   # 自己指定一個
~/.fluid/fluid.sh model claude auto     # 恢復成最便宜的那個
```

## 續跑

用量上限一重置，Claude Code 會自己把工作階段接著跑下去（`/config` 裡的 "Continue automatically at usage limit"）。但有時它沒接上 —— 誤按的一個鍵取消了倒數，或者倒數根本沒開始 —— 工作階段就一直停在那裡，直到你發現。Fluid 是最後一道防線：它的 hooks 模組記下停在上限上的工作階段，重置三分鐘後再看一眼，如果還停著，就像你一樣送出一句 `continue`。

除此之外它不插手。Claude Code 或你已經接著做了、或者輸入框裡有沒打完的內容，它都不會送出任何東西；最多試兩次，還不行就通知你。這需要安裝外掛，並且 Claude Code 會載入它的 hooks 模組。

## 提醒

Fluid 平時不出聲，只在需要你處理時才響，而且只報告六件事：

| | |
|---|---|
| **已登出** | 某個助手的登入已過期，在你重新登入之前它什麼都開不了 |
| **連續失敗** | 某個助手接連幾次保溫都失敗了 |
| **排程停了** | 排好的工作過了很久還沒執行，視窗沒有被保持開著；通常是 `atd` 沒在執行 |
| **恢復正常** | 從上面任一故障中恢復了 |
| **保溫模型失效** | 某個助手原本用來保溫的模型已經不存在了，之後改用它自己的預設模型 |
| **沒能續跑** | 用量上限重置後工作階段仍然停著，送出 `continue` 也沒讓它動起來 |

每件事按助手各通報一次，不會每次重試都響，所以過夜出問題只會收到一則訊息。自己恢復的故障則一聲不響：只有在稍後的重試也失敗之後，才會報某個助手已登出。撞到用量上限本身從不通知：那是常態，助手自己會接著做，它們沒接上時還有 Fluid。

想選擇用什麼方式收到訊息，複製一個範例過去，填上你自己的金鑰或伺服器：

```bash
cd ~/.fluid
cp notify/bark.sh.sample notify.sh      # 也可以是 ntfy.sh.sample、email.sh.sample
chmod +x notify.sh                      # 郵件那個用 700，裡面有密碼
$EDITOR notify.sh
./fluid.sh notify-test            # 確認收得到
```

通知指令碼不過是個可執行檔，執行時會拿到 `CP_EVENT`、`CP_MESSAGE`、`CP_HOST`，所以換成 Telegram、Slack、webhook 或 `mail`，無非是改一行。你的這份副本在重新安裝後依然保留。

## 檔案

全都在 `~/.fluid/` 底下：

| | |
|---|---|
| `fluid.sh` | 指令碼本體 |
| `providers/` | 每個助手一個檔案 |
| `state/<助手>/` | 該助手的視窗、排程和提醒狀態 |
| `notify.sh` | 你設定的通知指令碼 |
| `notify/` | 可複製的範例 |
| `anchor` | 你設定的視窗開啟時刻（如果設了） |
| `fluid.log` | 它都做了些什麼 |

## 解除安裝

```bash
npx fluid-agents uninstall
```

或者從原始碼：`bash install-fluid.sh uninstall`。

它會直接在每個助手的設定上修改，只拿掉 Fluid 自己加的東西：你原本的 status line 會回來，其他所有設定原樣保留 —— 包括安裝 Fluid 之後才加進去的。它排下的工作會被取消，`~/.fluid/` 會被刪除，你的 `notify.sh` 也在其中。重複執行不會有任何壞處。

如果之後有別的程式又把某個 status line 包在了 Fluid 外面，解除安裝不會把它弄壞：會留下一個小的透傳指令碼讓那個程式繼續運作，解除安裝時也會告訴你；等不再需要它時再執行一次解除安裝即可。同樣情況下升級，會留在那個程式的鏈裡，而不是反過來把它包起來。

解除安裝前那一刻每個設定檔都會留一份副本在旁邊，安裝時留下的副本也都還在（保留最近的五份），萬一需要手動回退可以用。

## 授權條款

GPL-3.0-or-later，詳見 [LICENSE](LICENSE)。
