# rustios — Rust for iOS (host and target)

[emexlab/LLVM-On-iOS](https://github.com/emexlab/LLVM-On-iOS) は clang/Swift を
**iOS 上で動く**クロスコンパイラとしてビルドし、`LLVM.xcframework` などに固めて
配布しています。このリポジトリは同じことを **Rust コンパイラ (rustc) で行う**
ものです。

つまり、出来上がるのは「iOS 用のコードを生成するコンパイラ」ではなく、

* **iOS (arm64) 上で動く rustc**
* その rustc が **iOS 16.0 向けにコンパイルする**ための標準ライブラリ

です。ビルドは macOS 上で行い、成果物は LLVM-On-iOS と同じ形で配布します。

| | LLVM-On-iOS | rustios |
| --- | --- | --- |
| ツールチェーン本体 | `SwiftToolchain.zip` | `RustToolchain-iphoneos-arm64-<ver>.tar.xz` |
| アプリに組み込むライブラリ | `LLVM.xcframework`（`llvm.a` + headers） | `Rust.xcframework`（C API + コンパイラ dylib） |
| サポートライブラリ | `CoreCompilerSupportLibs` | `RustSupportLibs-iphoneos-arm64-<ver>.tar.xz` |
| ターゲット | `arm64-apple-ios16.0` | `aarch64-apple-ios`（deployment target 16.0） |
| 生成方法 | `build-script --preset=nyxian_iphoneos_arm64_crosscompiler` | `x.py build --stage 2`（クロスホスト） |

Rust 側のターゲット名は `aarch64-apple-ios` ですが、これは LLVM-On-iOS が使う
`arm64-apple-ios16.0` と同じプラットフォームです（Apple の別名 arm64 = aarch64、
`IPHONEOS_DEPLOYMENT_TARGET=16.0`）。

---

## 成果物

タグ `v*` を push するか、Actions から手動でワークフローを実行すると、
次のファイルが生成され、Artifact としてアップロードされます。

| ファイル | 中身 |
| --- | --- |
| `RustToolchain-iphoneos-arm64-<ver>.tar.xz` | `RustToolchain/usr/{bin,lib}` — iOS で動く `rustc`, `rustdoc`, std, codegen backend |
| `RustToolchain-iphoneos-arm64-<ver>-usr.tar.xz` | 同じものを `usr/` 直下に持つアーカイブ（`RUST_DIR` をそのまま展開したい場合用） |
| `RustSupportLibs-iphoneos-arm64-<ver>.tar.xz` | iOS 向け LLVM 静的ライブラリと、`--sysroot` にそのまま渡せる `sysroot/`（std rlib + codegen backend） |
| `Rust.xcframework-iphoneos-arm64-<ver>.tar.xz` | `libRustCompiler.dylib`（C API）・コンパイラ dylib・`rustios.h` を収めた `Rust.xcframework` |
| `SHA256SUMS.txt` | 上記の SHA-256 |

`Rust.xcframework` は `rustc_private`（コンパイラ内部 API）に依存するため、
Rust のバージョンに強く依存します。ビルドに失敗した場合はワークフローが
失敗として扱われ、**中途半端な成果物が配布されることはありません**
（アップロードは `if-no-files-found: error`）。

LLVM-On-iOS の `LLVM.xcframework` は `libtool -static` で作った `llvm.a` を
含みますが、rustc は静的ライブラリにできません。上流の Rust は
`rustc_driver` を `crate-type = ["dylib"]` として定義しており、どの
プラットフォームにも `librustc_driver.a` は存在しないためです。そこで
`Rust.xcframework` は **動的ライブラリのスライス** になり、C API の
`libRustCompiler.dylib` と、それが実行時に読み込む
`librustc_driver-*.dylib` / `libstd-*.dylib` を同じスライスに同梱します。

---

## 使い方

### GitHub Actions

```sh
# 手動実行（バージョンなどを指定できる）
gh workflow run build-rust-ios.yml -f rust_version=1.99.1 -f ios_deployment_target=16.0

# タグを打つとビルド + Release 作成
git tag v1.99.1 && git push origin v1.99.1
```

ワークフローは `macos-14`（Apple Silicon）で動きます。

### ローカル

macOS + Xcode（iPhoneOS SDK）が必要です。

```sh
make            # fetch + configure + build + verify + package + support + xcframework
make -j1 build  # x.py build --stage 2 だけを実行（時間がかかる）
make info       # 現在の設定を表示
```

主な変数（環境変数でも上書き可）:

```sh
make RUST_VERSION=1.99.1 OS_VER=16.0 JOBS=8
```

| 変数 | 既定値 | 意味 |
| --- | --- | --- |
| `RUST_VERSION` | `1.99.1` | Rust のリリースタグ |
| `OS_VER` / `IOS_DEPLOYMENT_TARGET` | `16.0` | iOS deployment target（LLVM-On-iOS と同じ） |
| `HOST_TRIPLE` | `aarch64-apple-ios` | 生成する rustc が動くプラットフォーム |
| `STAGE` | `2` | bootstrap のステージ |
| `LLVM_TARGETS` | `AArch64` | LLVM のバックエンド（`AArch64` のみで十分） |
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

### LLVM を 2 回ビルドする理由

rustc は LLVM を静的リンクします。iOS で動く rustc には **iOS 用の LLVM** が
必要で、CI が配布している macOS 用 LLVM（`download-ci-llvm`）は使えません。
そのため bootstrap は

1. macOS 用 LLVM（stage1 rustc が動くため）
2. iOS 用 LLVM（stage2 rustc にリンクされる）

の両方をビルドします。`rust-source/build/<triple>/llvm` をキャッシュすると
2 回目以降は数十秒〜数分で済みます。

### bootstrap の iOS 対応パッチ

上流の bootstrap は、Apple のモバイル向けに LLVM をビルドするとき
(`configure_cmake`)、compiler-rt の都合で

```rust
cfg.define("CMAKE_SYSTEM_NAME", "Darwin");
cfg.define("CMAKE_OSX_SYSROOT", "/");
cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", "");
```

と上書きします。しかし **フルの LLVM** をこの設定でビルドすると iPhoneOS SDK
ではなく `/` を相手にコンパイルしてしまい、iOS のオブジェクトになりません。

`Scripts/build-rust-toolchain.sh` は `configure` の最後に
`patch_bootstrap_llvm()` でこのブロックだけを

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

### 検証

`make verify` は生成物が本当に iOS 用かどうかを確認します。

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
| rustc / clang の各コンパイル | sccache（`SCCACHE_GHA_ENABLED=true`）。bootstrap の `build.ccache = "sccache"` により LLVM の CMake ビルドにも効く |
| `rust-source`（Rust 本体 + サブモジュール） | `actions/cache`（`rust-src-*`） |
| `rust-source/build/*/llvm`（macOS 用・iOS 用） | `actions/cache`（`rust-llvm-*`、stage 1 終了時と最後の 2 回保存） |
| `rust-source/build/cache`（stage0 のダウンロード） | 同上 |

ビルドは **stage 1**（最初の LLVM と stage1 rustc）と **stage 2**（最終的な
iOS 用 rustc）に分かれていて、stage 1 の直後にもキャッシュを保存します。
クリーンな状態からの stage 2 は GitHub の 6 時間制限に収まらないことがある
ためで、途中で打ち切られても次の実行がその続きから始められます。

`Scripts/build-rust-toolchain.sh` の設定を変えたときは、ワークフローの
`CACHE_VERSION` / `LLVM_CACHE_VERSION` を上げてください。

---

## デバイス上での使い方

```sh
tar -xJf RustToolchain-iphoneos-arm64-1.99.1.tar.xz
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
tar -xJf Rust.xcframework-iphoneos-arm64-1.99.1.tar.xz
ls Rust.xcframework/ios-arm64
# Headers/  libRustCompiler.dylib  librustc_driver-<hash>.dylib  libstd-<hash>.dylib
```

`Headers/rustios.h` の `rustios_run()` に `rustc` と同じ引数を渡します。
`libRustCompiler.dylib` は `@rpath` でコンパイラ dylib を探すので、3 つの
dylib をすべてアプリの `Frameworks/` に置き、署名してください（Xcode なら
"Embed & Sign"、手動なら `-Wl,-rpath,@executable_path/Frameworks`）。

コンパイル対象の std は `RustSupportLibs` の `sysroot/` にあります。アプリに
同梱して `--sysroot` で渡してください（`rustc` がデバイス上で動くには、
リンカと iPhoneOS SDK も必要です）。

```c
#include <rustios.h>

const char *argv[] = {
    "rustc", "--sysroot", "/path/to/RustSupportLibs/sysroot",
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
* `Rust.xcframework` は動的ライブラリです（`rustc_driver` が dylib のため）。
  アプリには 3 つの dylib すべてを `Frameworks/` に埋め込み、署名してから
  使います。Xcode の Runpath Search Paths に `@executable_path/Frameworks`
  （既定値）が必要です。コード生成バックエンド（`RustSupportLibs/sysroot`）
  も同じ `@rpath` で `librustc_driver` を探します。C API のビルドに失敗した
  場合、スクリプトは警告を出してコンパイラ dylib 自体をスライスのライブラリ
  として収めます（`build-info.json` の `"c_api": false`）。
* ビルドには macOS ランナーと 1 時間以上の時間が必要です（LLVM を 2 回
  ビルドするため）。コールドビルドは GitHub Actions の 6 時間制限に
  収まらないことがあるので、キャッシュを温めてから実行してください。
* `LLVM_TARGETS` は既定で `AArch64` のみです。他のアーキテクチャ向けにも
  コンパイルしたい場合は `make LLVM_TARGETS="AArch64;X86"` のように指定します。

---

## ディレクトリ構成

```
.github/workflows/build-rust-ios.yml   CI（ビルド + キャッシュ + Release）
Makefile                               make all / fetch / configure / build / ...
Scripts/build-rust-toolchain.sh        ビルド本体（fetch/configure/build/package/...）
Scripts/rustios-driver/rustios_driver.rs   rustc を C API として公開する cdylib
Scripts/rustios-driver/include/rustios.h   その C ヘッダ
```

生成物（Git 管理外）:

```
rust-source/   Rust のチェックアウト（build/ 以下にビルド結果）
work/          パッケージング用の作業ディレクトリ
artifacts/     配布する tar.xz と SHA256SUMS.txt
```
