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
| アプリに組み込むライブラリ | `LLVM.xcframework`（`llvm.a` + headers） | `Rust.xcframework`（`libRustCompiler.a` + headers） |
| サポートライブラリ | `CoreCompilerSupportLibs` | `RustSupportLibs-iphoneos-arm64-<ver>.tar.xz` |
| ターゲット | `arm64-apple-ios16.0` | `aarch64-apple-ios`（deployment target 16.0） |
| 生成方法 | `build-script --preset=nyxian_iphoneos_arm64_crosscompiler` | `x.py build --stage 2`（クロスホスト） |

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

そのため `verify` / `package` / `support` は、出荷ツリーに macOS の Mach-O が
1 つでも混ざっていれば **失敗** します（`assert_ios_only`）。`vtool` で
`platform IOS` を確認し、`file` で arm64 であることも確認します。
ビルド途中の macOS 用成果物は `rust-source/build/aarch64-apple-darwin/` に
ありますが、`artifacts/` には入りません。

---

## 成果物

タグ `v*` を push するか、Actions から手動でワークフローを実行すると、
次のファイルが生成され、Artifact としてアップロードされます。

| ファイル | 中身 |
| --- | --- |
| `RustToolchain-iphoneos-arm64-<ver>.tar.xz` | `RustToolchain/usr/{bin,lib}` — iOS で動く `rustc`, `rustdoc`, std, codegen backend |
| `RustToolchain-iphoneos-arm64-<ver>-usr.tar.xz` | 同じものを `usr/` 直下に持つアーカイブ（`RUST_DIR` をそのまま展開したい場合用） |
| `RustSupportLibs-iphoneos-arm64-<ver>.tar.xz` | iOS 向け LLVM 静的ライブラリ（`llvm/lib/*.a`）と、`--sysroot` にそのまま渡せる `sysroot/`（std rlib + codegen backend）。`llvm-config` は macOS 用のビルドツールなので含めません |
| `Rust.xcframework-iphoneos-arm64-<ver>.tar.xz` | `libRustCompiler.a`（rustc 本体 + C API の静的ライブラリ）と `rustios.h` を収めた `Rust.xcframework` |
| `SHA256SUMS.txt` | 上記の SHA-256 |

`Rust.xcframework` は `rustc_private`（コンパイラ内部 API）に依存するため、
Rust のバージョンに強く依存します。ビルドに失敗した場合はワークフローが
失敗として扱われ、**中途半端な成果物が配布されることはありません**
（アップロードは `if-no-files-found: error`）。

`Rust.xcframework` は LLVM-On-iOS の `llvm.a` と同じく **静的ライブラリ**です。
`libRustCompiler.a` に rustc 本体（`rustc_driver_impl` 以降のクレート）と
C API がすべて入っていて、アプリにそのままリンクできます。

上流の Rust は `rustc_driver` を `crate-type = ["dylib"]` とし、ビルドした
rustc のクレートを `.rmeta` だけで配るため、素の状態では静的リンクできません
（`librustc_driver.a` は存在しません）。rustios は `configure` 時に
`patch_bootstrap_rustc_artifacts()` で bootstrap の
`ArtifactKeepMode::Custom` を書き換え、**rlib（オブジェクトファイル込み）を
sysroot に残す** ことで、stage1 の rustc から `--crate-type staticlib` で
1 本の `.a` を作れるようにしています。rlib が無い場合は、警告を出して
コンパイラ dylib をそのまま収めた動的スライスにフォールバックします
（`build-info.json` の `"c_api": false`）。

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
# Headers/  libRustCompiler.a
```

`libRustCompiler.a` は `llvm.a` と同じ使い方です。アプリにリンクし、
`Headers/rustios.h` の `rustios_run()` に `rustc` と同じ引数を渡します。

```sh
clang main.c Rust.xcframework/ios-arm64/libRustCompiler.a \
      -IRust.xcframework/ios-arm64/Headers -lc++ -lSystem -o app
```

Xcode なら `libRustCompiler.a` を "Frameworks, Libraries, and Embedded
Content" に追加（Embed は "Do Not Embed"）し、Other Linker Flags に
`-lc++ -lSystem` を足すだけです。std も `.a` に入っているので、dylib を
アプリに埋め込む必要はありません。

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
* `Rust.xcframework` は静的ライブラリ（`libRustCompiler.a`）です。ただし
  実行時に **コード生成バックエンド** を読み込むため、`RustSupportLibs` の
  `sysroot/lib/rustlib/aarch64-apple-ios/codegen-backends/*.dylib` をアプリに
  同梱して署名し、`--sysroot` でそのディレクトリを渡してください。rlib が
  残せなかったビルドでは、警告を出してコンパイラ dylib を収めた動的スライスに
  フォールバックします（`build-info.json` の `"c_api": false`）。
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
Scripts/rustios-driver/rustios_driver.rs   rustc を C API として公開する staticlib
Scripts/rustios-driver/include/rustios.h   その C ヘッダ
```

生成物（Git 管理外）:

```
rust-source/   Rust のチェックアウト（build/ 以下にビルド結果）
work/          パッケージング用の作業ディレクトリ
artifacts/     配布する tar.xz と SHA256SUMS.txt
```
