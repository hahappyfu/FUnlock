# FUnlock

> 靠近自动解锁，离开自动锁屏 —— 用蓝牙信号守护你的 Mac

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-lightgrey.svg)]()
[![Version](https://img.shields.io/badge/version-2.4.0-green.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)]()

FUnlock は iPhone / Apple Watch、または任意の Bluetooth Low Energy（BLE）デバイスの RSSI 信号強度を監視し、Mac を自動ロック・アンロックする macOS メニューバーユーティリティです。iPhone アプリは不要で、パスワードは Keychain に安全に保存されます。

---

## ✨ 主な機能

- **接近でアンロック** — スマホが Mac に近づくと自動的にパスワード入力でアンロック
- **離脱でロック** — スマホが範囲外になると自動的にスクリーンロック
- **iPhone アプリ不要** — macOS 側のみで実装、BLE 放送信号を利用
- **サイドバー ナビゲーション** — NSVisualEffectView の毛玻璃スタイル、7 つのタブで分類管理
- **マルチデバイス対応** — 複数の BLE デバイスを同時監視、自動スキャン + RSSI ソート
- **スマート信号処理** — 非対称カルマンフィルタ + 時間減衰パケットロスペナルティ
- **Wi-Fi 連動** — 指定 Wi-Fi 接続時にロックを一時停止（会社/家庭ネットワーク用）
- **マルチプロファイル** — 複数の設定を作成・切り替え可能
- **入力活動保護** — キーボード/トラックパッドの入力を検知し、ロックを猶予
- **手動ロック保護** — 手動ロック後の自動アンロックを禁止可能
- **自動更新** — 毎日 Gitee Release をチェックし、新バージョンを自動ダウンロード・インストール
- **セキュアストレージ** — パスワードは Keychain で暗号化保存
- **多言語対応** — 中国語、日本語、ドイツ語、スウェーデン語、ノルウェー語、デンマーク語、トルコ語

---

## 📦 インストール

### Homebrew Cask（推奨）

```bash
brew install funlock
```

### 手動インストール

1. [Releases](https://gitee.com/fuhahah/funlock/releases) から最新バージョンをダウンロード
2. 解凍後、`FUnlock.app` を `/Applications` フォルダに移動
3. 初回起動時に Bluetooth とアクセシビリティの権限を付与

---

## 🚀 クイックスタート

1. FUnlock を起動し、メニューバーに Bluetooth アイコンが表示される
2. アイコンをクリックしてコントロールパネルを開く
3. 「デバイス」タブで iPhone または Apple Watch を選択
4. ロック/アンロックの RSSI しきい値を調整（デフォルト: -80 / -60 dBm）
5. Mac ログインパスワードを入力（Keychain に安全保存）

完了！Mac から離れると自動ロック、戻ると自動アンロック。

---

## 🧭 コントロールセンター

メニューバーのアイコンをクリックしてサイドバー ナビゲーション コントロールセンターを開きます：

| タブ | 機能 |
|------|------|
| **概要** | 信号ダッシュボード、RSSI、しきい値調整、校正ウィザード |
| **デバイス** | ペアリング済みデバイス、BLE 自動スキャン、デバイス一覧 |
| **基本** | 有効/無効、ログイン時自動起動 |
| **アンロック** | 接近時ウェイク、ウェイクのみアンロックしない、スクリーンセーバー |
| **ロック** | メディア一時停止、モニター OFF、遅延ロック、手動ロック後アンロック禁止 |
| **ネットワーク** | Wi-Fi 一時停止（SSID 指定）、パッシブモード |
| **プロファイル** | マルチプロファイル管理 |

---

## 🛡️ セキュリティ設計

- **Keychain 暗号化**：`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` で保存、デバイスロック時は読み取り不可
- **競合保護**：手動アンロック後 3 秒間は自動アンロックを禁止
- **システムロック監視**：`com.apple.screenIsLocked` 通知を監視
- **SQL パラメータ化クエリ**：Bluetooth データベースはパラメータバインドでインジェクション防止
- **codesign 検証**：自動更新時にアプリ署名を検証

---

## 🔧 スクリプトイベント

ロック/アンロック時にスクリプトを自動実行：

```
~/Library/Application Scripts/FUnlock/event
```

引数形式：`event rssi deviceName timestamp`

| イベント | 説明 |
|----------|------|
| `away` | デバイスが離脱、自動ロック |
| `lost` | 信号消失、自動ロック |
| `unlocked` | FUnlock が自動アンロック |
| `intruded` | ユーザーが手動アンロック（FUnlock 以外） |

---

## 📁 プロジェクト構成

```
FUnlock/
├── FUnlock/
│   ├── AppDelegate.swift              # アプリエントリ + 権限チェック
│   ├── FUnManager.swift               # コアステートマシン（@MainActor）
│   ├── FUn.swift                      # CoreBluetooth + 信号フィルタリング
│   ├── MenuDashboardView.swift        # サイドバー ナビゲーション
│   ├── SystemInteractionService.swift # ロック/ウェイク/パスワード入力
│   ├── SecurityService.swift          # Keychain 読み書き
│   ├── ScriptRunner.swift             # スクリプトイベント実行
│   ├── TelemetryLogger.swift          # 構造化ログ + 埋め込み
│   ├── UpdateDownloader.swift         # 自動更新ダウンローダー
│   ├── UpdateInstaller.swift          # 自動更新インストーラー
│   └── ...（他多数）
├── Launcher/                           # ログイン時自動起動 Helper
└── docs/                               # 開発ドキュメント
```

---

## 🏗️ アーキテクチャ

```
┌─────────────────────────────────────────────┐
│       MenuDashboardView (サイドバー)         │
│         コントロールセンター                   │
└──────────────────┬──────────────────────────┘
                   │ @Published state
┌──────────────────▼──────────────────────────┐
│          FUnManager (@MainActor)             │
│    ステートマシン：ScreenState + LockIntent    │
└──────────────────┬──────────────────────────┘
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│SystemInt.│ │Security  │ │ Script   │
│Service   │ │Service   │ │ Runner   │
└──────────┘ └──────────┘ └──────────┘

┌─────────────────────────────────────────────┐
│              FUn (CoreBluetooth)             │
│    非対称 Kalman + 時間減衰フィルタ            │
└─────────────────────────────────────────────┘
```

---

## 🛠️ 開発

### ビルド

```bash
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release
```

### 要件

- Xcode 15+
- macOS 13.0+ デプロイターゲット
- Swift 5.7+

---

## 📝 License

MIT License

Copyright © 2019-2026 Takeshi Sone. 二次開発維持 by fuhahah.
