# rustios

Rust コンパイラ (rustc) を **iOS 向け** にビルドするためのリポジトリです。
参考にした [emexlab/LLVM-On-iOS](https://github.com/emexlab/LLVM-On-iOS) と同じ考え方で、
「iOS の上で *動く* ツールチェーン」を作ります。

| LLVM-On-iOS | rustios |
| --- | --- |
| `SwiftToolchain.zip` (iOS 上で動く Swift/clang ツールチェーン) | `RustToolchain-iphoneos-arm64-<ver>.tar.xz` |
| `LLVM.xcframework` (アプリに組み込める LLVM 静的ライブラリ) | `Rust.xcframework` (`librustc_driver` + C API) |
| `CoreCompilerSupportLibs.tar.xz` | `RustSupportLibs-iphoneos-arm64-<ver>.tar.xz` |
| ターゲット: `arm64-apple-ios16.0` | `aarch64-apple-ios` (deployment target `16.0`) |
| クロスビルド: `host = iphoneos-arm64` | クロスホスト: `build = aarch64-apple-darwin`, `host = target = aarch64-apple-ios` |

`emexlab` のワークフローは成果物が実際には出てこない状態 (`make all` は
`LLVM.xcframework` しか作らないのに `CoreCompiler.framework` をアップロードしようとする、
`if: ${{ false }}` のジョブがある、アップロード手順に `if: always()` がない) ですが、
**rustios は必ず成果物が出るように作っています** (下記参照)。

---

## 成果物

| ファイル | 内容 |
| --- | --- |
| `RustToolchain-iphoneos-arm64-<ver>.tar.xz` | iOS (arm64) 上で動く `rustc` / `rustdoc` / std / codegen backend |
| `RustSupportLibs-iphoneos-arm64-<ver>.tar.xz` | iOS 向け LLVM 静的ライブラリ + std rlib + codegen backend (LLVM-On-iOS の `CoreCompilerSupportLibs` 相当) |
| `Rust.xcframework-iphoneos-arm64-<ver>.tar.xz` | `librustc_driver` を静的ライブラリ化した `Rust.xcframework` + `rustios.h` (best effort) |
| `SHA256SUMS.txt` | 上記のチェックサム |
| `rust-ios-logs-<run>` (Actions artifact) | ビルドログ (失敗時も必ずアップロード) |

タグ (`v*`) を push すると GitHub Release にも自動で添付されます。

### RustToolchain の中身

```
RustToolchain/
├── USAGE.md
├── build-info.json
└── usr/
    ├── bin/rustc            # Mach-O 64-bit executable arm64 / platform IOS
    ├── bin/rustdoc
    └── lib/rustlib/aarch64-apple-ios/
        ├── lib/*.rlib       # std, core, alloc, ... (arm64)
        └── codegen-backends/*.dylib
```

実機での使い方 (LLVM-On-iOS の Swift ツールチェーンと同じ要領):

```sh
export RUST_DIR=/path/to/RustToolchain/usr
export PATH="$RUST_DIR/bin:$PATH"

rustc --edition 2021 -C opt-level=2 hello.rs -o hello
```

`rustc` はリンカ (`ld` / `ld64`) と iPhoneOS SDK を必要とします。
同梱の Mach-O はすべて ad-hoc 署名 (`codesign -s -`) 済みです
(jailbreak / TrollStore 環境で `dyld` / `dlopen` が通るようにするため)。

### Rust.xcframework

iOS アプリに Rust コンパイラそのものを組み込み、アプリ内でコンパイルしたい場合の
成果物です (LLVM-On-iOS の `CoreCompiler.framework` の Rust 版)。

```c
#include <rustios.h>

const char *argv[] = {
    "rustc",
    "--sysroot", "/path/to/RustToolchain/usr",
    "--edition", "2021",
    "-C", "opt-level=2",
    "/tmp/hello.rs",
    "-o", "/tmp/hello",
    NULL,
};
int rc = rustios_run(9, argv);   /* 0 = success */
```

このステップはコンパイラ内部 API (`rustc_private`) に依存するため
**best effort** です。失敗してもツールチェーンの成果物は必ず出ます
(ワークフロー側で `continue-on-error`)。

---

## GitHub Actions

`.github/workflows/build-rust-ios.yml`

* トリガー: `push` (main / `v*` タグ), `pull_request` (ビルド関連ファイルのみ), `workflow_dispatch`
* ランナー: `macos-14` (Apple Silicon)
* 入力 (手動実行時): Rust のバージョン、iOS deployment target、channel、
  xcframework を作るか、sccache を使うか

### キャッシュ戦略

| キャッシュ | 手段 | キー |
| --- | --- | --- |
| rustc / clang の各コンパイル | **sccache** (`SCCACHE_GHA_ENABLED=true`, GitHub Actions キャッシュサービス) | 自動 |
| LLVM ビルド (macOS 用 + iOS 用) | `actions/cache` (`rust-build/<triple>/llvm`) | `rust-llvm-<CACHE_VERSION>-<LLVM_CACHE_VERSION>-<rust version>-<ios target>` |
| bootstrap の stage0 ダウンロード | `actions/cache` (`rust-build/cache`) | 同上 |

* LLVM は **2 回** ビルドします。macOS 上で動く rustc 用と、iOS 上で動く rustc 用です。
  iOS 用 LLVM は `librustc_driver` に静的リンクされるため、CI 配布の macOS LLVM は使えません
  (`llvm.download-ci-llvm = false`)。
* LLVM の設定を変えたときは `LLVM_CACHE_VERSION` を上げてください。
* コールドビルドで約 1.5〜3 時間、LLVM キャッシュヒット時で約 30〜60 分が目安です
  (3 コア / 7 GB の `macos-14`)。

### 成果物が必ず出る仕組み

1. `make`/スクリプト側で**実際に生成されたものだけ**を決まった名前で `artifacts/` に出力する
   (`Scripts/build-rust-toolchain.sh package|support|xcframework`)。
2. アップロード手順は `if-no-files-found: error`。存在しなければワークフローが落ちるので、
   「成功したのに成果物がない」状態にならない。
3. 失敗時も `if: always()` でログと `SHA256SUMS.txt` をアップロード。
4. `SHA256SUMS.txt` を同時に生成し、Release にも添付。

---

## ローカルビルド

macOS (Xcode + iPhoneOS SDK) が必要です。LLVM を 2 回ビルドするので時間とディスクに注意
(合計 15〜20 GB 程度)。

```sh
git clone https://github.com/<you>/rustios.git
cd rustios

make            # toolchain + support libs + xcframework
# または個別に
make fetch      # Rust ソースを取得 (shallow clone + 必要な submodule のみ)
make configure  # rust-source/bootstrap.toml を生成
make build      # x.py build --stage 2 (host=aarch64-apple-ios)
make verify     # 生成物が iOS/arm64 か確認 (file / lipo / vtool)
make package    # RustToolchain-*.tar.xz
make toolchain  # = verify + package
make support    # RustSupportLibs-*.tar.xz
make xcframework
make clean      # ビルド出力を削除
make clean-all  # Rust のチェックアウトごと削除
```

主な環境変数:

```sh
RUST_VERSION=1.99.1            # Rust のタグ
RUST_CHANNEL=stable            # stable / nightly / dev (空なら自動)
IOS_DEPLOYMENT_TARGET=16.0     # LLVM-On-iOS の OS_VER と同じ
HOST_TRIPLE=aarch64-apple-ios
STAGE=2
LLVM_TARGETS=AArch64         # Intel ビルドホストでは自動で `;X86` が付く
JOBS=$(sysctl -n hw.ncpu)
BUILD_XCFRAMEWORK=true
```

---

## 仕組み

`rustc` は「動くホスト」と「コンパイル対象のターゲット」を分けてビルドできます。
rustios は rust-lang/rust 標準の bootstrap (`x.py`) の**クロスホストビルド**を使います。

```
[build]
build  = "aarch64-apple-darwin"   # ビルドを行う macOS
host   = ["aarch64-apple-ios"]    # 生成される rustc が動く場所 (iPhone)
target = ["aarch64-apple-ios"]    # その rustc がコンパイルする対象
```

1. stage0 コンパイラ (macOS) をダウンロード
2. stage1 コンパイラ (macOS 上で動く rustc) をビルド
   * そのために macOS 用 LLVM をビルド
3. stage1 が iOS 用 LLVM をクロスビルド
4. stage1 が `--target aarch64-apple-ios` で stage2 rustc をビルド
5. iOS 用 std は stage1 でビルドし、stage2 に uplift

`IPHONEOS_DEPLOYMENT_TARGET=16.0` を設定してビルドするので、成果物の
`LC_BUILD_VERSION` は `platform IOS, minos 16.0` になります
(`make verify` で確認できます)。

### bootstrap へのパッチ (iOS 用 LLVM)

そのままの bootstrap では、Apple のモバイル向けに LLVM をクロスビルドするとき
`CMAKE_SYSTEM_NAME` を `Darwin`、`CMAKE_OSX_SYSROOT` を `/`、
deployment target を空文字に上書きします (`configure_cmake` 内、upstream の FIXME)。
これは compiler-rt 向けの回避策で、**フルの LLVM をビルドすると iPhoneOS SDK ではなく
`/` を相手にコンパイルしてしまい、iOS のオブジェクトにならない/失敗する**原因になります。

rustios は `Scripts/build-rust-toolchain.sh` の `patch_bootstrap_llvm()` でこのブロックだけを

```rust
if let Ok(sdk) = std::env::var("RUSTIOS_IOS_SDK") {
    cfg.define("CMAKE_SYSTEM_NAME", "iOS");
    cfg.define("CMAKE_OSX_SYSROOT", sdk);
    cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", /* RUSTIOS_IOS_DEPLOYMENT_TARGET */);
} else {
    // upstream の Darwin / sysroot "/" フォールバック
}
```

に置き換えます (`build` が SDK パスと deployment target を環境変数で渡します)。

* パッチは冪等です (適用済みなら `bootstrap already patched` と表示)。
* 置換対象が想定と違う場合 (Rust 側でコードが変わった場合) は**警告して続行**します。
  その場合は `RUSTIOS_IOS_SDK` が無視されるため、LLVM のビルドが失敗する可能性があります。
* compiler-rt (sanitizer runtime) はこの経路を使わないよう `[build] sanitizers = false`
  にしています。
* `bootstrap.toml` には `[build] submodules = false` を書き、必要な submodule
  (`src/llvm-project`, `library/backtrace`) だけを `fetch` で取得します。

---

## 制約・既知の問題

* **cargo / rustfmt / clippy は未同梱**。`cargo` はビルドスクリプトや `rustc` を
  子プロセスとして起動するため、iOS のサンドボックス下では追加の仕組み
  (LLVM-On-iOS/Nyxian の micro kernel 的なもの) が必要です。
* **実機で実行するには署名が必要**です。ad-hoc 署名は付けてありますが、
  TrollStore / jailbreak / 自前の provisioning profile など、環境に合わせて
  再署名してください。
* リンクには `ld`/`ld64` と iPhoneOS SDK が必要です。
* LLVM のターゲットは `AArch64` のみ (ビルド時間短縮のため)。
  `LLVM_TARGETS` で変更できます。
* `Rust.xcframework` はコンパイラ内部 API に依存するため best effort です。
* ビルドには macOS ランナーが必要です (Apple の SDK / リンカを使うため)。

## ライセンス

rustios 自体のビルドスクリプトは MIT / Apache-2.0 のデュアルライセンスとします。
生成物 (rustc, std, LLVM) は Rust / LLVM の各ライセンスに従います。
