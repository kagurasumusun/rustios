# rustios — Rust for iOS (host and target)

[emexlab/LLVM-On-iOS](https://github.com/emexlab/LLVM-On-iOS) は clang/Swift を
**iOS 上で動く**クロスコンパイラとしてビルドし、`LLVM.xcframework` などに固めて
配布しています。このリポジトリは同じことを **Rust コンパイラ (rustc) で行う**
ものです。

つまり、出来上がるのは「iOS 用のコードを生成するコンパイラ」ではなく、

* **iOS (arm64) 上で動く rustc**
* その rustc が **iOS 16.0 向けにコンパイルする**ための標準ライブラリ

です。ビルドは macOS 上で行い、成果物は LLVM-On-iOS と同じ形で配布します。

さらに rustios は、**Swift コンパイラと LLVM を共有**します。Swift 6.4 をビルドする
LLVM（`swiftlang/llvm-project` 21.1.6）をそのまま Rust のコンパイラにもリンクさせ、
rust-lang 版 LLVM を別にビルドしません。詳細とバージョンの根拠は
[docs/llvm-sharing.md](docs/llvm-sharing.md)。

| | LLVM-On-iOS | rustios |
| --- | --- | --- |
| Swift ツールチェーン | `SwiftToolchain.zip` | `SwiftToolchain-iphoneos-arm64-6.4.0.tar.xz` |
| 共有 LLVM | `LLVM.xcframework`（`llvm.a` + headers） | `SwiftLLVM-iphoneos-arm64-21.1.6.tar.xz` + `LLVM.xcframework` |
| Rust ツールチェーン本体 | — | `RustToolchain-iphoneos-arm64-<ver>.tar.xz` |
| アプリに組み込むライブラリ | `LLVM.xcframework` | `Rust.xcframework`（`libRustCompiler.a`。静的化の段階は実行ごとに `build-info.json`） |
| サポートライブラリ | `CoreCompilerSupportLibs` | `RustStd-iphoneos-arm64-<ver>.tar.xz`（std。LLVM は `SwiftLLVM` を共有） |
| ターゲット | `arm64-apple-ios16.0` | `aarch64-apple-ios`（deployment target 16.0） |
| LLVM | 21.1.6（Swift 6.4） | **同じ 21.1.6 を両方のコンパイラで共有** |
| 生成方法 | `build-script --preset=nyxian_iphoneos_arm64_crosscompiler` | 同じプリセット相当 + `x.py build --stage 2`（クロスホスト） |

Rust 側のターゲット名は `aarch64-apple-ios` ですが、これは LLVM-On-iOS が使う
`arm64-apple-ios16.0` と同じプラットフォームです（Apple の別名 arm64 = aarch64、
`IPHONEOS_DEPLOYMENT_TARGET=16.0`）。

### 「macOS 用」ではなく「iOS 用」です

macOS は **ビルドを実行する環境** であって、成果物のターゲットではありません。
iOS 用のコンパイラを作るには Xcode と iPhoneOS SDK が必要なので、ビルド自体は
macOS 上で動きます（LLVM-On-iOS も `macos-latest` でビルドしています）。

| | 何のため | 成果物に入るか |
| --- | --- | --- |
| ビルドマシン `aarch64-apple-darwin`（`x86_64-apple-darwin`） | Xcode / clang / CMake を動かす土台 | **入りません** |
| ビルドマシン用 LLVM・std・stage1 rustc | ビルド中にだけ使う道具 | **入りません** |
| iOS `aarch64-apple-ios` 用 LLVM | iOS で動く rustc に静的リンクされる | 入ります（iOS/arm64） |
| iOS 用 rustc / rustdoc / std / codegen backend | デバイス上で動くコンパイラ本体 | 入ります（iOS/arm64） |

そのため `verify` / `package` / `std` は、出荷ツリーに macOS の Mach-O が
1 つでも混ざっていれば **失敗** します（`assert_ios_only`）。`vtool` で
`platform IOS` を確認し、`file` で arm64 であることも確認します。
ビルド途中の macOS 用成果物は `rust-source/build/aarch64-apple-darwin/` に
ありますが、`artifacts/` には入りません。

Swift の成果物だけは事情が異なります。クロスビルドでは `swift-frontend`
（= iOS で動くコンパイラ本体）は iOS/arm64 ですが、その隣にホスト用の
ツール（macOS 版のドライバなど）も出力されます。LLVM-On-iOS も同じ構成
（`lib/swift/host/compiler/*.dylib` を同梱）なので、Swift 側は
「**コンパイラ本体が iOS であること**」を必須条件にし、それ以外は
iOS / ホストの **内訳を数えてレポートに明記** します（黙って iOS と
称さないため）。Rust 側の成果物は従来どおり全ファイル iOS/arm64 必須です。

---

## 成果物

タグ `v*` を push するか、Actions から手動でワークフローを実行すると、
次のファイルが生成され、Artifact としてアップロードされます。

| ファイル | 中身 |
| --- | --- |
| `SwiftToolchain-iphoneos-arm64-6.4.0.tar.xz` | iOS で動くコンパイラ本体 `swift-frontend`（IOS/arm64）。`swiftc`/`swift-driver` は macOS のホストドライバで、LLVM-On-iOS の `SwiftToolchain.zip` と同じ構成。384 MB |
| `SwiftLLVM-iphoneos-arm64-21.1.6.tar.xz` | **共有 LLVM**。`SwiftLLVM/{macosx,ios}/{bin/llvm-config,include,lib/*.a}`。Rust のビルドはこれをそのまま使う |
| `LLVM.xcframework-iphoneos-arm64-21.1.6.tar.xz` | `llvm.a` + headers（LLVM-On-iOS の `LLVM.xcframework` 相当）。44 MB |
| `RustToolchain-iphoneos-arm64-<ver>.tar.xz` | `RustToolchain/usr/{bin,lib}` — iOS で動く `rustc`, `rustdoc`, codegen backend。**std は含みません** |
| `RustStd-iphoneos-arm64-<ver>.tar.xz` | **std のみ**（`RustStd/usr/lib/rustlib/aarch64-apple-ios/lib/*.rlib`）。コンパイラとは別配布 |
| `Rust.xcframework-iphoneos-arm64-<ver>.tar.xz` | `Rust.xcframework`。静的 `libRustCompiler.a` を目指し、(1) C API 付き静的 → (2) C API なしの静的（rlib のオブジェクトを 1 本に）→ (3) 動的スライスの順に試します。どれになったかは `build-info.json` の `"c_api"` / `"library"`（docs/llvm-sharing.md §6） |
| `SHA256SUMS.txt` | 上記の SHA-256 |

**std はツールチェーンに入れません。** サイズの大半を占めるうえ、デバイス上で
コンパイルしないなら不要だからです。Swift 側が
「コンパイラ（`SwiftToolchain`）＋ LLVM（`LLVM.xcframework`）＋ サポート
ライブラリ」に分かれているのと同じ考え方で、Rust 側も
「コンパイラ（`RustToolchain`）＋ std（`RustStd`）＋ `Rust.xcframework`」に
分けています。LLVM は Swift の `SwiftLLVM` を共有するので、Rust 用の
LLVM コピー（以前の `RustSupportLibs`）はもうありません。

`RustStd` は `RustToolchain/usr` にそのまま重ねられる形なので、まとめて使うなら:

```sh
tar -xJf RustToolchain-iphoneos-arm64-<ver>.tar.xz
tar -xJf RustStd-iphoneos-arm64-<ver>.tar.xz -C RustToolchain
```

分けたまま使うなら `rustc --sysroot="$PWD/RustStd/usr" ...` を毎回渡します。

`Rust.xcframework` は `rustc_private`（コンパイラ内部 API）に依存するため、
Rust のバージョンに強く依存します。ビルドに失敗した場合はワークフローが
失敗として扱われ、**中途半端な成果物が配布されることはありません**
（アップロードは `if-no-files-found: error`）。

`Rust.xcframework` は LLVM-On-iOS の `llvm.a` と同じく **静的ライブラリ**に
することを目標にしています（`libRustCompiler.a` = rustc 本体 + C API）。
段階は 3 つあり、上から順に試して、成立したものを配布します。

1. **C API 付きの静的ライブラリ** — `rustios.h` + `libRustCompiler.a`。
   `rustc_driver_impl` を静的リンクし、`rustios_run()` を公開します。**未達**。
2. **C API なしの静的ライブラリ** — rlib の中のオブジェクトを
   `libtool -static` で 1 本にまとめます（`"c_api": false`）。crate の
   メタデータが要るのは C シムだけなので、オブジェクトの結合は通ります。
   **現在はこれ**（展開 685 MB、xz 96 MB）。
3. **動的スライス** — 上記が両方失敗した場合のみ（`librustc_driver-*.dylib`）。

1 が失敗してきた理由: `rustc_driver_impl` の rlib は見つかるのですが、その
依存 `derive_where`（proc-macro）を rustc が解決できません。sysroot にある
`librustc_driver_impl` は stage 1 の sysroot からコピーされたもので、stage 0
（rustc 1.93）がビルドした `derive_where` を要求する一方、crate hash は cargo
の unit から決まるため **ファイル名が同じで中身の stage だけが違う**コピーが
並びます。そのため探索範囲を広げても正しい組を選べず、`E0463`（見つからない）
か `E0514`（rustc 1.93 製）になります。現在は `--extern` で stage 2 の
ドライバを明示する方式を試しています。結果は `build-info.json` と `REPORT.txt`
に残ります。詳細は
[docs/llvm-sharing.md §6](docs/llvm-sharing.md) に記録しています。

上流の Rust は `rustc_driver` を `crate-type = ["dylib"]` とし、ビルドした
rustc のクレートを `.rmeta` だけで配るため（`librustc_driver.a` は存在しません）、
rustios は `configure` 時に `patch_bootstrap_rustc_artifacts()` で bootstrap の
`ArtifactKeepMode::Custom` を書き換え、**rlib（オブジェクトファイル込み）を
sysroot に残す**ようにしています。これで rlib は揃うので、残る課題は
上記の依存解決だけです。

---

## 使い方

### GitHub Actions

```sh
# 手動実行（バージョンなどを指定できる）
gh workflow run build-rust-ios.yml -f rust_version=1.94.0 -f ios_deployment_target=16.0

# タグを打つとビルド + Release 作成
git tag v1.94.0 && git push origin v1.94.0
```

ワークフローは `macos-latest`（Apple Silicon）で、2 つのジョブに分かれています。

1. `swift` — Swift 6.4 と LLVM 21.1.6 を iOS 向けにビルドし、`SwiftLLVM` /
   `SwiftToolchain` / `LLVM.xcframework` を artifact として上げる（約 4 時間）
2. `build` — その `SwiftLLVM` をダウンロードして rustc をビルドする
   （`src/llvm-project` は取得しない。LLVM のビルドは無い）

`RUST_VERSION` を変えるときは、そのタグが想定する LLVM の major.minor を
確認してください（[docs/llvm-sharing.md](docs/llvm-sharing.md) の対応表）。

### Rust 半分だけを、既にある `SwiftLLVM` から作る

`build-rust-from-artifact` は、**Swift をビルドし直さずに** 既存の
`swift-llvm` artifact をダウンロードして Rust 側だけをビルドします
（artifact は 90 日保持）。Swift と Rust は 1 つの run の 2 ジョブなので、
Rust 側だけやり直したいときに 4.5 時間の Swift ビルドをやり直さずに済み、
**push でキャンセルされない** 独立した concurrency グループを持ちます。

```sh
# 方法 1: GitHub UI（Actions → build-rust-from-artifact → Run workflow）
#         source_run_id が空なら「最新の swift-llvm artifact」を使う
#         ※ workflow_dispatch には actions:write 権限が要る

# 方法 2: トリガーファイルを push（contents:write だけで起動できる）
#         .github/rust-from-artifact.trigger に run id を書く（空なら最新）
```

長時間ビルドが **push でキャンセルされない** ようにしてあります:
`build-rust-ios` は `cancel-in-progress: false`（実行中のビルドは残り、待機中の
run だけが新しい push に置き換わります）、`build-rust-from-artifact` は run ごとに
別の concurrency グループを持つので、そもそも待機・置換が起きません。

どの run の LLVM を使ったかは、ジョブの「Show environment」と PR コメント
（`swift-llvm from: …/runs/<id>`, commit）に記録されます。LLVM は作り直さず、
Swift ジョブも走らせません。これは「rustc が Swift の LLVM をリンクできるか」
を最短で確かめる経路でもあります。

### ローカル

macOS + Xcode（iPhoneOS SDK）が必要です。

```sh
make            # LLVM → fetch → configure → build → verify → package → std
make llvm       # Swift の LLVM（macOS + iOS）だけを作る。Rust 側はこれが必須
make swift      # その LLVM から iOS 用 Swift コンパイラまで作る（+ verify/package）
make build      # rustc のビルドだけ（SwiftLLVM が既にある場合）
make info       # 現在の設定を表示
```

主な変数（環境変数でも上書き可）:

```sh
make RUST_VERSION=1.94.0 OS_VER=16.0 JOBS=8
make RUST_LLVM_MODE=intree   # 比較用: rust-lang 版 LLVM を bootstrap にビルドさせる
```

| 変数 | 既定値 | 意味 |
| --- | --- | --- |
| `RUST_VERSION` | `1.94.0` | Rust のリリースタグ（LLVM 21.1.x のもの） |
| `RUST_LLVM_MODE` | `swift` | `swift` = Swift の LLVM を共有 / `intree` = 従来通り自分でビルド |
| `SWIFT_BRANCH` | `swift-6.4.0-RELEASE` | 共有する LLVM の元になる Swift のリリース |
| `SWIFT_LLVM_DIR` | `work/SwiftLLVM` | 共有 LLVM のインストール先 |
| `OS_VER` / `IOS_DEPLOYMENT_TARGET` | `16.0` | iOS deployment target（LLVM-On-iOS と同じ） |
| `HOST_TRIPLE` | `aarch64-apple-ios` | 生成する rustc が動くプラットフォーム |
| `STAGE` | `2` | bootstrap のステージ |
| `LLVM_TARGETS` | `AArch64` | `intree` モードで bootstrap がビルドする LLVM のバックエンド（`swift` モードでは未使用） |
| `JOBS` | CPU 数 | 並列度 |

---

## 仕組み

### クロスホストビルド

`x.py` の `build` / `host` / `target` を分けます。

```
build  = aarch64-apple-darwin   # ビルドを実行する macOS
host   = aarch64-apple-ios      # 生成された rustc が動く場所
target = aarch64-apple-ios      # その rustc がコンパイルする対象
```

`Scripts/build-rust-toolchain.sh configure` が `rust-source/bootstrap.toml` を
生成します:

```toml
[build]
build = "aarch64-apple-darwin"
host = ["aarch64-apple-ios"]
target = ["aarch64-apple-ios"]
```

### なぜ 2 段階なのか

rustc のホストを iOS にすると、**ビルドマシン上で動くコンパイラ**がまず必要です
（stage0 のバイナリは iOS 用の std を作れません: bootstrap が
`It is not possible to build the standard library for aarch64-apple-ios using the
stage0 compiler` で止まります）。そこで bootstrap を 2 回に分けて実行します。

```sh
# 1) ビルドマシン用: stage1 rustc + iOS 用 std（LLVM は Swift のものをリンク）
x.py build --stage 1 --host aarch64-apple-darwin

# 2) iOS 用: iOS で動く stage2 rustc（同じく Swift の LLVM をリンク）
x.py build --stage 2 --host aarch64-apple-ios compiler
```

`Scripts/build-rust-toolchain.sh build` は既定でこの 2 つを順に実行します
（`RUSTIOS_BUILD_PHASE=host` / `target` で個別に実行でき、CI はその間に
キャッシュを保存します）。2 段目に `compiler` というパスを渡すのは、
ビルドマシン用の stage2 rustc まで作ってしまうのを避けるためです。

### LLVM は 1 つだけ: Swift が使う LLVM を共有する

rustc も swiftc も LLVM を静的リンクします。iOS で動く rustc には **iOS 用の
LLVM** が必要で、CI が配布している macOS 用 LLVM（`download-ci-llvm`）は使えません。
ここで rust-lang 版 LLVM を別にビルドすると LLVM が 2 つになってしまうので、
rustios は **Swift をビルドした LLVM をそのまま Rust にも使います**。

```
Swift 6.4 ──┬── swift-frontend (iOS/arm64)
             └── rustc          (iOS/arm64)      ← 同じ libLLVM*.a をリンク
```

`Scripts/build-rust-toolchain.sh configure` は `bootstrap.toml` に次を書きます。

```toml
[target."aarch64-apple-darwin"]
llvm-config = "work/SwiftLLVM/macosx/bin/llvm-config"
llvm-has-rust-patches = false

[target."aarch64-apple-ios"]
llvm-config = "work/SwiftLLVM/ios/bin/llvm-config"
llvm-has-rust-patches = false
```

bootstrap は `llvm-config` が指定された target の LLVM を「ビルド済み」として
扱う（`prebuilt_llvm_config() -> AlreadyBuilt`）ので、**`src/llvm-project` は
configure もビルドもされません**（サブモジュールとして取得すらしません）。
`llvm-has-rust-patches = false` により `LLVM_RUSTLLVM` も定義されず、
rust-lang のパッチを前提としたコードパスに入りません。

`llvm-config` は `SwiftLLVM/*/bin/llvm-config` に生成します。iOS 用の
`llvm-config` は macOS 上で実行できないため、実物の回答を取り込んだ
再配置可能なシェルスクリプトにしています（`Scripts/llvm-config-shim.py`）。
詳しくは [docs/llvm-sharing.md](docs/llvm-sharing.md)。

`make RUST_LLVM_MODE=intree` にすると以前の動作（bootstrap が
`rust-lang/llvm-project` をビルド）に戻ります。比較用で、既定ではありません。

### bootstrap の iOS 対応パッチ（`intree` モードのみ）

上流の bootstrap は、Apple のモバイル向けに LLVM をビルドするとき
(`configure_cmake`)、compiler-rt の都合で

```rust
cfg.define("CMAKE_SYSTEM_NAME", "Darwin");
cfg.define("CMAKE_OSX_SYSROOT", "/");
cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", "");
```

と上書きします。しかし **フルの LLVM** をこの設定でビルドすると iPhoneOS SDK
ではなく `/` を相手にコンパイルしてしまい、iOS のオブジェクトになりません。

`Scripts/build-rust-toolchain.sh` は `RUST_LLVM_MODE=intree` のとき `configure` の
最後に `patch_bootstrap_llvm()` でこのブロックだけを

```rust
if let Ok(sdk) = std::env::var("RUSTIOS_IOS_SDK") {
    cfg.define("CMAKE_SYSTEM_NAME", "iOS");
    cfg.define("CMAKE_OSX_SYSROOT", sdk);
    cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", /* RUSTIOS_IOS_DEPLOYMENT_TARGET */);
} else {
    // 上流の Darwin / sysroot "/" フォールバック
}
```

に置き換えます。`SDKROOT` はビルドホスト（macOS）側のビルドを壊すので
**export しません**。iOS 向けのコンパイルだけが `xcrun` 経由で SDK を得ます。

パッチは冪等で、適用済みなら何もしません。対象のコードが変わっていて
適用できない場合は警告を出して続行します（その場合 LLVM のビルドは失敗します）。
既定の `RUST_LLVM_MODE=swift` では LLVM をビルドしないため、このパッチは
適用しません（`configure` がその旨を表示します）。

### 検証

その前に `Scripts/build-rust-toolchain.sh preflight` が数秒で「この LLVM を
実際にリンクできるか」を確認します（`ios/lib` に無いライブラリ、iOS 側に混ざった
macOS のアーカイブ、ヘッダとバージョンの major の不一致など。放っておくと 2 段の
ビルドが終わった後のリンクエラーになるもの）。

`make verify` は 2 つを確認します。

**(1) Swift の LLVM が本当に使われたか**（`verify_llvm_source`）。
「llvm-config を差し替えた」だけでは証明にならないので、ビルドの生成物から
確認し、1 つでも欠ければ失敗します。

* `bootstrap.toml` の `[target.*] llvm-config` が `work/SwiftLLVM/...` を指す
* ツリー内 LLVM のビルドディレクトリ（`build/*/llvm/build`）が存在しない
* `rustc_llvm` のビルドスクリプト出力が `SwiftLLVM` 配下をリンク先にしている
  （＝ cargo がそのまま rustc のリンク行に使う値）

さらに `SwiftLLVM/ios/llvm-config.log` に、ビルド中に呼ばれた引数が残ります。

**(2) 生成物が本当に iOS 用かどうか。**

```
$ file  rust-source/build/aarch64-apple-ios/stage2/bin/rustc
... Mach-O 64-bit executable arm64
$ vtool -show-build rust-source/build/aarch64-apple-ios/stage2/bin/rustc
... platform IOS
... minos 16.0
```

---

## キャッシュ（GitHub Actions）

| 対象 | 方法 |
| --- | --- |
| `swift-source`（Swift + llvm-project ほか sibling リポジトリ） | `actions/cache`（`swift-src-*`）。リリースごとに不変 |
| `rust-source`（Rust 本体 + `library/backtrace`） | `actions/cache`（`rust-src-*`） |
| 共有 LLVM（ビルド済み） | `swift` ジョブ → `build` ジョブへ **artifact**（`SwiftLLVM-*.tar.xz`）で受け渡し |
| Swift / LLVM のビルドツリー | キャッシュしない（数十 GB で上限 10 GB を超える） |
| stage0 のダウンロード | bootstrap が `build/cache` に保持（ジョブ内のみ） |

LLVM を Rust 側でビルドしないため、`rust-llvm-*` キャッシュは廃止しました。
`swift` ジョブは LLVM →（artifact 公開）→ Swift の順に進むので、Swift の
ビルドが時間切れになっても LLVM の成果物は残ります。

`sccache` は使いません（GitHub Actions バックエンドの一時的なストレージ
エラーでコンパイル自体が落ちるため）。

`Scripts/` の設定を変えたときは、ワークフローの `CACHE_VERSION` を上げてください。

---

## デバイス上での使い方

```sh
tar -xJf RustToolchain-iphoneos-arm64-1.94.0.tar.xz
export RUST_DIR="$PWD/RustToolchain/usr"
export PATH="$RUST_DIR/bin:$PATH"

rustc --version
rustc --edition 2021 -C opt-level=2 hello.rs -o hello
```

`hello` のリンクには Mach-O リンカ（`ld`/`ld64`）と iPhoneOS SDK が必要です。
jailbreak / TrollStore 環境や、Nyxian のような IDE の中では、その環境が
提供するリンカ・SDK を `-C linker=...` や `-C link-arg=-isysroot...` で
指定してください。`--emit=obj` や rlib の生成はリンカなしで動きます。

同梱の Mach-O はすべて ad-hoc 署名（`codesign -s -`）済みです。アプリに
組み込む場合は、アプリ本体の署名に合わせて再署名してください。

### アプリから rustc を呼ぶ（`Rust.xcframework`）

```sh
tar -xJf Rust.xcframework-iphoneos-arm64-1.94.0.tar.xz
ls Rust.xcframework/ios-arm64
# 現在:   libRustCompiler.a のみ（C API なし）
# 目標:   Headers/rustios.h + libRustCompiler.a
```

```sh
clang main.c Rust.xcframework/ios-arm64/libRustCompiler.a \
      -IRust.xcframework/ios-arm64/Headers -lc++ -lSystem -o app
```

Xcode なら `libRustCompiler.a` を "Frameworks, Libraries, and Embedded
Content" に追加（Embed は "Do Not Embed"）し、Other Linker Flags に
`-lc++ -lSystem` を足すだけです。std も `.a` に入っているので、dylib を
アプリに埋め込む必要はありません。

コンパイル対象の std は `RustStd` にあります。アプリに同梱して `--sysroot`
で渡してください（`rustc` がデバイス上で動くには、リンカと iPhoneOS SDK も
必要です）。

```c
#include <rustios.h>

const char *argv[] = {
    "rustc", "--sysroot", "/path/to/RustStd/usr",
    "--emit=obj", "hello.rs", "-o", "hello.o",
};
int rc = rustios_run(7, argv);   /* RUSTIOS_OK=0, RUSTIOS_FAILED=1, ... */
```

`rustios_run()` は同期・非再入です。rustc はグローバル状態を持つため、
同時に複数スレッドから呼ばないでください。ICE でプロセスが壊れる可能性が
あるので、`RUSTIOS_ICE`（101）が返ったら以降の呼び出しは避けてください。

---

## 制約

* **cargo は同梱していません。** cargo は子プロセスとして rustc を起動する
  ため、iOS のサンドボックスでは追加の仕組み（LLVM-On-iOS/Nyxian の
  micro kernel 相当）が必要になります。rustc 単体は動きます。
* `rustc` がデバイス上で動くには、署名済みの実行ファイルであること、
  およびリンカ・SDK が存在することが必要です。
* `Rust.xcframework` は `rustc_private` を使うため、Rust のバージョン間で
  互換性がありません。`build-info.json` のバージョンと合わせて使ってください。
* `Rust.xcframework` は静的ライブラリ（`libRustCompiler.a`）です。ただし
  実行時に **コード生成バックエンド** を読み込むため、`RustToolchain` の
  `usr/lib/rustlib/aarch64-apple-ios/codegen-backends/*.dylib` をアプリに
  同梱して署名し、`--sysroot` でそのディレクトリを渡してください。C シムが
  リンクできなかったビルドでは `"c_api": false` の静的アーカイブ（C API
  なし）、rlib すら残せなかったビルドでは動的スライスになります。どれも
  `build-info.json` の `"library"` / `"c_api"` を見れば分かります。
* ビルドには macOS ランナーと 1 時間以上の時間が必要です（LLVM を 2 回
  ビルドするため）。コールドビルドは GitHub Actions の 6 時間制限に
  収まらないことがあるので、キャッシュを温めてから実行してください。
* `LLVM_TARGETS` は既定で `AArch64` のみです。他のアーキテクチャ向けにも
  コンパイルしたい場合は `make LLVM_TARGETS="AArch64;X86"` のように指定します。

---

## ディレクトリ構成

```
.github/workflows/build-rust-ios.yml      CI（swift ジョブ → build ジョブ + Release）
Makefile                                  make all / llvm / swift / build / ...
docs/llvm-sharing.md                      共有 LLVM の設計・バージョン対応表・未検証項目
Scripts/build-swift-toolchain.sh          Swift 6.4 と LLVM 21.1.6（macOS/iOS）のビルド
Scripts/swift-ios-toolchain-presets.ini   LLVM-On-iOS 相当の build-script プリセット
Scripts/llvm-config-shim.py               再配置可能な llvm-config の生成
Scripts/build-rust-toolchain.sh           rustc のビルド（fetch/configure/build/package/...）
Scripts/rustios-driver/rustios_driver.rs  rustc を C API として公開する staticlib
Scripts/rustios-driver/include/rustios.h  その C ヘッダ
```

生成物（Git 管理外）:

```
swift-source/  Swift と llvm-project のチェックアウト（build/ 以下にビルド結果）
rust-source/   Rust のチェックアウト（build/ 以下にビルド結果）
work/          SwiftLLVM（共有 LLVM）とパッケージング用の作業ディレクトリ
artifacts/     配布する tar.xz と SHA256SUMS.txt
```
