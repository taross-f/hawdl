# hawdl

macOS の `awdl0` を落としたまま維持し続けるツール。

*[English README](README.md)*

`awdl0` (Apple Wireless Direct Link) は Wi-Fi と同じ無線を時分割で共有する。
有効なままだとスループットが落ち、レイテンシにスパイクが出る。
`sudo ifconfig awdl0 down` で落とせるが、AirDrop / Handoff / Sidecar の起動や
スリープ復帰のたびに OS が勝手に up に戻す。

hawdl は「一度落とす」のではなく **落とした状態を維持し続ける**。

```
┌─────────────┐     ┌──────────┐
│ HawdlBar.app│     │ hawdl CLI│   ← ユーザー権限
└──────┬──────┘     └────┬─────┘
       └────────┬────────┘
         Unix domain socket
         /var/run/hawdl.sock
                │
         ┌──────▼──────┐
         │   hawdld    │              ← root (LaunchDaemon)
         │  PF_ROUTE 監視              │
         │  SIOCSIFFLAGS で down       │
         │  desired state 永続化        │
         └─────────────┘
```

root 権限が必要な操作をデーモンに閉じ込めているので、GUI と CLI は sudo を要求しない。

---

## ⚠️ 副作用 — 先に読むこと

`awdl0` を止めている間、以下は **動作しなくなる**:

- AirDrop
- Handoff / ユニバーサルクリップボード
- Sidecar
- ユニバーサルコントロール
- 連係カメラ / 連係マークアップ
- AirPlay の一部 (ピアツーピア接続)

これらが必要になったら `hawdl release` かメニューバーの「AWDL を再開」で戻せる。
`hawdld` を停止したときも自動で `up` に戻る。

### 免責

`awdl0` の直接操作は **Apple の公式サポート外**。macOS のアップデートで挙動が変わる、
あるいは動かなくなる可能性がある。このツールは MIT ライセンスで **無保証** で提供される。
使用は自己責任で。

---

## スクリーンショット

<!-- TODO: メニューバーを開いた状態のスクリーンショットを docs/menu.png に置いて差し替える -->
![HawdlBar のメニュー](docs/menu.png)

<!-- TODO: `hawdl watch` の出力のスクリーンショット / asciinema を docs/watch.png に置いて差し替える -->
![hawdl watch](docs/watch.png)

---

## インストール

### リリースビルドを使う

タグを打つたびに、`hawdl` / `hawdld` / `HawdlBar.app` を含む universal な
tarball (Apple Silicon と Intel の両対応) が publish される。
[Releases](https://github.com/taross-f/hawdl/releases) から取得して:

```sh
tar xzf hawdl-<version>-macos-universal.tar.gz
cd hawdl-<version>-macos-universal
xattr -dr com.apple.quarantine .
```

**このビルドは署名も公証もされていない**。ダウンロードすると macOS が隔離属性を
付けるため、外さないと Gatekeeper に弾かれる。以降の手順 (LaunchDaemon の
plist を含む) は tarball 内の `INSTALL.md` を参照。

### personal tap 経由

```sh
brew tap taross-f/hawdl
brew install --HEAD taross-f/hawdl/hawdl
```

> 現在の formula は head-only なので `--HEAD` が要る。タグ付きリリースが出たら不要になる。
> formula の実体は本リポジトリではなく
> [taross-f/homebrew-hawdl](https://github.com/taross-f/homebrew-hawdl) にあり、
> 二重管理を避けるため一箇所に集約している。

**デーモンの起動は必須**。これをやらないと `hawdl` も HawdlBar も話し相手がいない:

```sh
sudo brew services start hawdl
```

`sudo` が要るのは、インターフェースのフラグ変更が root 権限を必要とするため。
Homebrew の LaunchDaemon として `/Library/LaunchDaemons` に登録され、再起動後も自動で立ち上がる。

### メニューバーアプリ

formula は `HawdlBar.app` を Homebrew の prefix 内に組み立てる。**必須なのは
起動すること** — 自動で起動するものは何もなく、動いていなければメニューバーには
何も出ない。インストールに失敗したようにしか見えない:

```sh
open "$(brew --prefix hawdl)/HawdlBar.app"
```

.app はどこに置いてあっても起動できるので、これだけで足りる。`/Applications` への
リンクは任意の利便性 ― Spotlight と Launchpad に出るようになり、
システム設定 → 一般 → ログイン項目 での表示もまともになる ― であって、
起動できるようにするための手順ではない:

```sh
ln -sfn "$(brew --prefix hawdl)/HawdlBar.app" /Applications/HawdlBar.app
```

formula 自身が `/Applications` に書き込むことはできない。`brew install` は
サンドボックス下で動き、自分の prefix 内にしか書けないため。Cask にすれば
`/Applications` に入るが、Cask が入れるのは*ダウンロードした*成果物で、macOS は
それを隔離する。このアプリは署名されていないので、その場合 Gatekeeper に
弾かれる。ローカルビルドであることが隔離属性を回避している。

`LSUIElement` が立っているので Dock にアイコンは出ない。メニューバーだけに常駐する。

### ソースからビルド

```sh
git clone https://github.com/taross-f/hawdl.git
cd hawdl
swift build -c release
swift test
```

必要環境: macOS 14 (Sonoma) 以降、Swift 5.9 以降。外部パッケージ依存はゼロ。

`hawdl` と `hawdld` は `.build/release` から直接実行できる。メニューバーアプリは
できない ― SwiftPM が吐くのは素のバイナリで、`MenuBarExtra` が `LSUIElement` を
効かせるには実体のあるバンドルが要る。組み立てる:

```sh
mkdir -p HawdlBar.app/Contents/MacOS
cp .build/release/HawdlBar HawdlBar.app/Contents/MacOS/
cp Sources/HawdlBar/Resources/Info.plist HawdlBar.app/Contents/
codesign --force --deep --sign - HawdlBar.app
open HawdlBar.app
```

**`codesign` は省略不可**。`swift build` は素のバイナリを ad-hoc 署名するため、
後から `Info.plist` を足すとバンドルが署名後に変わった状態になり、macOS は起動を
拒否する。エラーも出ずメニューバーにも出ないので、「アプリが何もしていない」ように
しか見えない。`codesign --verify --deep --strict HawdlBar.app` で判別できる。

---

## 使い方

```
hawdl status     現在の状態を表示
hawdl hold       awdl0 を落としたまま維持する
hawdl release    維持をやめて awdl0 を up に戻す
hawdl watch      状態変化を購読して流し続ける

  --socket <path>   制御ソケット (default: /var/run/hawdl.sock)
  --json            生の JSON を出力
  --version / --help
```

```console
$ hawdl hold
AWDL: held down  blocked=0  daemon=0.1.0

$ hawdl status
AWDL: held down  blocked=12  last=2025-09-07T10:23:45Z  daemon=0.1.0

$ hawdl watch
AWDL: held down  blocked=12  last=2025-09-07T10:23:45Z  daemon=0.1.0
AWDL: held down  blocked=13  last=2025-09-07T10:24:02Z  daemon=0.1.0
```

終了コード: `0` 正常 / `1` エラー / `2` 引数の誤り / `3` `hawdld` に接続できない。

### メニューバー

| アイコン | 意味 |
| --- | --- |
| `antenna.radiowaves.left.and.right.slash` | hold 中 (awdl0 停止) |
| `antenna.radiowaves.left.and.right` | release 中 (awdl0 動作) |
| `exclamationmark.triangle` | `hawdld` に未接続、または awdl0 が存在しない |

`wifi` 系は意図的に避けている。`wifi.slash` は macOS が *Wi-Fi オフ* に使って
いるグリフそのもので、awdl0 を止めても Wi-Fi は切れないため、そう見せてはいけない。
`wifi` に至ってはシステムの Wi-Fi メニュー項目と同一のグリフで、数ピクセル隣に
並ぶことになる。シンボルが利用できない場合はログを出して置き換え前の `wifi` 系に
フォールバックする。メニューバーに何も出ないほうが、誤解を招くアイコンより悪いため。

メニューから状態表示、停止 / 再開のトグル、ログイン時に起動 (`SMAppService`)、
`hawdld` のステータス確認ができる。デーモンが動いていなくてもクラッシュせず、
3 秒間隔で再接続を試みながら起動コマンドを案内する。

---

## 動作の詳細

- **監視は PF_ROUTE**。`RTM_IFINFO` を購読してイベント駆動で up を検知するので、
  AirDrop を開いた瞬間に反応する。ポーリングではない。
- **保険として 30 秒ごとの reconcile** も回す。イベントを取りこぼしても最大 30 秒で復旧する。
- **インターフェース操作は ioctl**。`ifconfig` をサブプロセスで叩かず、
  `SIOCGIFFLAGS` / `SIOCSIFFLAGS` で `IFF_UP` を直接操作する。
- **フラップ防止**。10 秒以内に 5 回以上 up されたら指数バックオフ (1s → 2s → 4s … 上限 30s) を挟む。
  OS と無限に殴り合って CPU を焼かないための安全弁。バックオフ中は
  「インターフェースが静かになってから 1 ウィンドウ分」経つまで抜けない
  (単純なスライディングウィンドウだと、遅延がウィンドウを追い越した瞬間に
  カウンタが空になって高速リトライに逆戻りしてしまうため)。
- **desired state は永続化される**。`/Library/Application Support/hawdl/state.json` に保存し、
  デーモン起動時に復元する。再起動しても hold は続く。
- **終了時は必ず up に戻す**。SIGTERM / SIGINT を受けたら `awdl0` を戻してから終了するので、
  デーモンが死んだのに AirDrop が使えない、という状態にはならない。
- **`awdl0` が無い環境**ではエラーで落ちず、`unavailable` を返してアイドルする。

---

## セキュリティ上の注意

**`/var/run/hawdl.sock` のパーミッションは 0666 です。**
つまり **同一マシンのローカルユーザーなら誰でも `awdl0` をトグルできます**。
リモートからは触れませんが、共用 Mac やゲストアカウントがある環境では、
他のユーザーがあなたの AirDrop を無効化したり、逆に hold を解除したりできます。

これは、メニューバーアプリが毎回 sudo を要求せずに済むようにするための意図的な妥協です。
将来的に `admin` グループ限定 (`root:admin` + 0660) に絞る TODO が
`Sources/HawdlCore/IPCServer.swift` にコメントとして残してあります。

デーモン自身は root で動きますが、公開しているのは
「`awdl0` の `IFF_UP` を読み書きする」という 1 つの操作だけです。
任意コマンド実行や任意インターフェース操作の口は開けていません。

---

## IPC プロトコル

`/var/run/hawdl.sock` 上の、改行区切り JSON。1 行 1 メッセージ。

リクエスト:

```json
{"cmd": "status"}
{"cmd": "hold"}
{"cmd": "release"}
{"cmd": "subscribe"}
```

レスポンス / プッシュ:

```json
{"actual":"down","available":true,"daemonVersion":"0.1.0","desired":"hold","flapCount":12,"lastFlapAt":"2025-09-07T10:23:45Z"}
```

| フィールド | 意味 |
| --- | --- |
| `desired` | `hold` / `release` — ユーザーが望んでいる状態 |
| `actual` | `up` / `down` / `unavailable` / `unknown` — 実際の `awdl0` の状態 |
| `available` | `awdl0` がこのマシンに存在するか (`actual != "unavailable"`) |
| `flapCount` | hold 中に OS が up に戻した回数 |
| `lastFlapAt` | 直近のフラップ時刻 (ISO 8601 / UTC)。一度も無ければキー自体が省略される |
| `daemonVersion` | `hawdld` のバージョン |

`subscribe` の場合は接続を維持し、状態が変わるたびにプッシュする。

```sh
# nc でも喋れる
echo '{"cmd":"status"}' | nc -U /var/run/hawdl.sock
```

---

## アンインストール

```sh
# 1. デーモンを止める (このとき awdl0 は up に戻る)
sudo brew services stop hawdl

# 2. 実際に戻ったことを確認する
ifconfig awdl0 | head -1
#   awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1484
#                  ^^ UP が入っていること

# 3. HawdlBar を終了し、リンクを張っていた場合は外す
rm -f /Applications/HawdlBar.app

# 4. アンインストール
brew uninstall hawdl
brew untap taross-f/hawdl

# 5. 残った状態ファイルを消す
sudo rm -rf "/Library/Application Support/hawdl"
```

`UP` が入っていない場合は `sudo ifconfig awdl0 up` で手動で戻せる。
ログイン項目に HawdlBar を登録していた場合は、システム設定 →
一般 → ログイン項目 から外すこと。

---

## 開発

```sh
swift test                    # HawdlCore のユニットテストと IPC の結合テスト
swift build -c release
```

テストは root も実機の `awdl0` も要求しない。インターフェース操作は
`InterfaceController` プロトコルの背後にあり、テストでは `FakeInterfaceController` を注入する。

デーモンのロジックを root なしで動かしたいとき:

```sh
.build/debug/hawdld --dry-run --socket /tmp/hawdl.sock --state /tmp/hawdl-state.json --verbose
.build/debug/hawdl status --socket /tmp/hawdl.sock
```

実機で確認するとき (AirDrop を開いて即座に down に戻ることを見る):

```sh
sudo .build/debug/hawdld --verbose
# 別のターミナルで
.build/debug/hawdl hold
.build/debug/hawdl watch
# → AirDrop を開くと flapCount が増え、awdl0 がすぐ down に戻る
```

### 構成

| ターゲット | 中身 |
| --- | --- |
| `HawdlCore` | 状態機械、バックオフ、IPC プロトコルとソケット、状態の永続化、インターフェース抽象 |
| `CHawdlSys` | C シム。`SIOCGIFFLAGS` / `SIOCSIFFLAGS` は `_IOWR()` マクロ由来で Swift から import できず、`ioctl(2)` は C 可変長引数、`struct ifreq` の無名共用体も import が安定しないため。外部依存ではなく本パッケージの一部 |
| `hawdld` | LaunchDaemon。PF_ROUTE 監視、タイマー、シグナル、ソケットサーバの配線 |
| `hawdl` | CLI |
| `HawdlBar` | SwiftUI `MenuBarExtra` のメニューバーアプリ |

**`IPCServer` をホストするプロセスは SIGPIPE を無視すること** (`hawdld` は `run()` で実施済み)。
ソケットには可能な限り `SO_NOSIGPIPE` を設定するが、`accept` が返る時点で既に相手が
切断している場合はその設定自体が失敗する ― そしてまさにその接続への返信が
SIGPIPE を上げる。Darwin には per-write の `MSG_NOSIGNAL` が無いため、
プロセスレベルの disposition だけが完全な対策になる。

---

## ライセンス

MIT. [LICENSE](LICENSE) を参照。
