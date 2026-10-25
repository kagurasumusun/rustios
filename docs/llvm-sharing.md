# Swift の LLVM を Rust と共有する

このリポジトリの iOS ツールチェーンは、**1 つの LLVM** から 2 つのコンパイラを作ります。

```
swiftlang/llvm-project  (LLVM 21.1.6)
        │
        ├── swift-frontend / swiftc   （iOS/arm64 で動く）
        └── rustc                     （iOS/arm64 で動く）
```

`src/llvm-project`（rust-lang 版 LLVM）を bootstrap にビルドさせる経路は使いません。
Rust 側から見ると「LLVM を自分でビルドする代わりに、Swift が使っている LLVM の
静的ライブラリをそのままリンクする」という構成です。

- Swift 側: `Scripts/build-swift-toolchain.sh`
- Rust 側: `Scripts/build-rust-toolchain.sh`（`RUST_LLVM_MODE=swift` が既定）
- CI: `.github/workflows/build-rust-ios.yml` の `swift` ジョブ → `build` ジョブ

---

## 0. 成果物の構成（Swift 側と揃える）

Swift 側（LLVM-On-iOS）は「コンパイラ」「LLVM」「サポートライブラリ」が別々の
成果物です。Rust 側も同じ形にそろえ、**std をツールチェーンから分離**しました。

| Swift (LLVM-On-iOS) | rustios | 中身 |
| --- | --- | --- |
| `SwiftToolchain.zip` | `RustToolchain-iphoneos-arm64-<ver>.tar.xz` | コンパイラ本体（`rustc` / `rustdoc` / codegen backend / `librustc_driver*.dylib`）。**std を含まない** |
| （対応物なし） | `RustStd-iphoneos-arm64-<ver>.tar.xz` | **std のみ**（`RustStd/usr/lib/rustlib/aarch64-apple-ios/lib/*.rlib`） |
| `LLVM.xcframework` | `Rust.xcframework-iphoneos-arm64-<ver>.tar.xz` | `libRustCompiler.a` + `Headers/rustios.h` |
| `LLVM.xcframework` | `SwiftLLVM-iphoneos-arm64-21.1.6.tar.xz` / `LLVM.xcframework-…` | **共有 LLVM**（Swift ジョブが生成。Rust 側はコピーを持たない） |

以前の `RustSupportLibs`（LLVM のコピー + std）は廃止しました。LLVM は Swift の
成果物をそのまま使うので Rust 用の複製は不要で、std は `RustStd` に移しました。

`RustStd` は `RustToolchain/usr` にそのまま重ねられるので、

```sh
tar -xJf RustToolchain-iphoneos-arm64-<ver>.tar.xz
tar -xJf RustStd-iphoneos-arm64-<ver>.tar.xz -C RustToolchain   # 完成した sysroot になる
```

あるいは分けたまま `rustc --sysroot="$PWD/RustStd/usr" ...` と渡せます。

### 現状（2026-10-24）

| 要求 | 状態 |
| --- | --- |
| Swift コンパイラを iOS 向けにビルドする | **CI で成功**（Swift 6.4、`swift-frontend` は IOS/arm64、`SwiftToolchain` 384 MB。`swiftc`/`swift`/`swift-driver` は macOS のホストドライバ） |
| Swift が使う LLVM を iOS 設定でビルドする | **CI で成功**（`SwiftLLVM` 96 MB、`LLVM.xcframework` 44 MB。iOS 側 `lib/*.a` のメンバーを `vtool` で検査し `IOS/arm64` を確認） |
| Rust を Swift の LLVM でビルドする | **CI で成功**（run 40144263022）。`RustToolchain` 35 MB + `RustStd` 256 MB + `Rust.xcframework` 30 MB。`verify` が「Swift の LLVM を使った」ことをビルド生成物から確認 |
| Rust 専用の LLVM を別にビルドしない | **実装済み**（`src/llvm-project` を fetch しない、`llvm-config` を渡す、`llvm-tools=false`） |
| バージョン整合の証拠 | §1 / §2 |
| std をツールチェーンから分離 | **実装済み**（`RustStd`）。`RustToolchain` 側に std が漏れていないことを `package` が確認 |
| 未完了項目の明示 | §6 |

CI の履歴:

1. `--skip-build-swift` が `build-script` に拒否される → 1 回のビルドに統合。
2. `llvm-targets-to-build=AArch64` で compiler-rt の builtins が失敗
   （`-arm-add-build-attributes`）。
3. LLVM 既定の全ターゲットではビルド成功するが、パッケージ中に 355 分で打ち切り。
4. `AArch64;ARM;X86` + 360 分: **Swift + LLVM のビルド成功**（4 時間 21 分）。
   `swiftc` が macOS バイナリだったため検証で停止し、Rust ジョブはスキップ。
   → 検証を「`swift-frontend` は iOS 必須、他は内訳をレポート」に変更し、
   `SwiftLLVM` ができていれば Rust ジョブを実行するようにした。
5. ビルド成功（4 時間 29 分）→ `Verify the LLVM slices` で失敗:
   `__.SYMDEF in libLLVMCore.a is none, not IOS`。Darwin の ar はアーカイブの
   先頭に**シンボルテーブル**（`__.SYMDEF`）を入れており、これは Mach-O では
   ない。→ メンバー一覧から `SYMDEF*` を除外し、複数メンバーを確認するよう修正。
   加えて、**パッケージとアップロードを検証より前に**移した（4.5 時間のビルドを
   検証のバグで捨てないため）。ビルド成果物（`work/SwiftLLVM` と
   `work/SwiftToolchain`）をキャッシュするようにもした。
6. 「Swift を回さず、既存の `swift-llvm` で Rust だけをビルドする」
   `build-rust-from-artifact` を追加（run 40019585601 の artifact を使用）。
   Rust 側の修正を 4 回まわし、いずれも数分〜20 分で結果が出た:
   * `FileCheck ... does not exist`（38 秒）→ `codegen-tests = false`
   * `submodule src/llvm-project ... required`（34 秒）→
     `optimized-compiler-builtins = false`
   * `no matching constructor for 'PGOOptions'`（3 分 53 秒）→ patch 0001
   * `ld: library 'stdc++' not found`（stage 2 のリンク）→ patch 0002
   * **run 40144263022: 成功**（`RustToolchain` 35 MB / `RustStd` 256 MB /
     `Rust.xcframework` 30 MB）。stage 1 + stage 2 でおよそ 30 分。
7. 4.5 時間のビルドが push で消える問題への対処: `cancel-in-progress: false`
   （実行中の run は残り、待機中だけが置き換わる）と、`build-rust-from-artifact`
   の run ごとの concurrency グループ。
8. Swift の検証が落ちた原因を特定して修正:
   * `swiftc` は macOS（仕様どおり）。`swift-frontend` は IOS/arm64 で、要求は満たす。
   * パッケージ先が `SWIFT_INSTALL_DIR` と同じで、自分自身を `usr/usr/usr/...` と
     無限にコピーしていた（`File name too long`）→ `work/package/` に分離。
   * 検証がパッケージより前で、5.5 時間のビルドが成果物ゼロで終わっていた
     → パッケージ・アップロードを先に、検証を最後に。
   * 2 ジョブが同じ PR コメントを奪い合い、失敗理由が消えていた → ジョブごとの
     コメント（`Scripts/pr-report.sh`、マーカーで自分のコメントを探して編集）。
   * ビルドキャッシュのキーがスクリプト全体のハッシュで、検証コードの修正でも
     5.5 時間の再ビルドになっていた → プリセット＋手動の `SWIFT_BUILD_RECIPE`。
     復元したツリーはキー一致ではなく**中身**で判定する。

---

## 1. バージョンの対応関係

| 項目 | 値 | 根拠 |
| --- | --- | --- |
| Swift | `swift-6.4.0-RELEASE` | `utils/update-checkout --tag swift-6.4.0-RELEASE` |
| swiftlang/llvm-project | `903b9faa…`（`swift/release/6.4.0`） | 上記タグが指す llvm-project |
| **Swift の LLVM** | **21.1.6** | `llvm/CMakeLists.txt` → `cmake/Modules/LLVMVersion.cmake` |
| `llvm-config --version`（Swift のビルド） | **21.0.0** | Swift のビルドが `-DPACKAGE_VERSION=21.0.0` を渡すため（`CLANG_USER_VISIBLE_VERSION`）。**ソース/API は 21.1.6** |
| Rust | `1.94.0` | `RUST_VERSION` の既定値 |
| rust-lang/llvm-project | `00d23d10…`（`rustc/21.1-2025-08-01`） | `1.94.0` の `src/llvm-project` サブモジュール |
| **Rust が想定する LLVM** | **21.1.8** | 同じく `LLVMVersion.cmake` |

`1.94.0` を選んだ理由は、**LLVM の major.minor が一致する唯一の組み合わせ**だからです。

| Rust | 同梱 LLVM | Swift | 判定 |
| --- | --- | --- | --- |
| 1.92.0 | 21.1.3 | 6.4.0 (21.1.6) | major.minor 一致（1.92 でも可） |
| **1.94.0** | **21.1.8** | **6.4.0 (21.1.6)** | **採用: 21.1 系、patch 差のみ** |
| 1.95.0 – 1.98.x | 22.1.x | 6.4.0 (21.1.6) | ✗ major.minor 不一致 |
| 1.99.1（以前の既定） | 23.1.1 | 6.4.0 (21.1.6) | ✗ major.minor 不一致 |
| 任意 | – | main / next (24.0.0git) | ✗ リリースされていない |

方針は「major.minor が同じなら patch 差は許す」。21.1.6 と 21.1.8 は同じ
`release/21.x` 系列で、差はバグ修正のみです。

> **`llvm-config --version` が 21.0.0 を返す理由**: Swift のビルドは
> `swift/utils/build_swift/build_swift/defaults.py` の
> `CLANG_USER_VISIBLE_VERSION = Version('21.0.0')` を `-DPACKAGE_VERSION` として
> LLVM に渡します。そのため `llvm-config --version` は 21.0.0 になりますが、
> **チェックアウトされているソースとヘッダは 21.1.6**（`LLVMVersion.cmake`、
> コミット `903b9faa`）です。rustc がコンパイルする相手はヘッダとライブラリ
> なので、実際の API は 21.1.6 です。bootstrap の検査は major のみ（≥ 20）なので
> 影響しません。レポートには両方の数字を記録します。

> **注意**: bootstrap 自身はこの対応を検査しません（後述のとおり
> 「LLVM ≥ 20」しか見ない）。この表が唯一の根拠なので、`RUST_VERSION` を
> 上げるときは必ず新しいタグの `src/llvm-project/cmake/Modules/LLVMVersion.cmake`
> を確認してください。

---

## 2. Rust 側が LLVM に要求するもの

`1.94.0` の bootstrap / rustc_llvm が実際に使う契約は次の 4 つです。

### 2.1 `llvm-config` があれば LLVM は「ビルド済み」になる

`src/bootstrap/src/core/config/toml/target.rs` の `llvm-config` にパスを書くと、
`build_steps/llvm.rs::prebuilt_llvm_config()` は

```rust
if let Some(config) = builder.config.target_config.get(&target)
    && let Some(ref s) = config.llvm_config
{
    check_llvm_version(builder, s);
    ...
    return LlvmBuildStatus::AlreadyBuilt(LlvmResult { host_llvm_config, llvm_cmake_dir });
}
```

を返し、**その target 用の LLVM は configure もビルドもされません**
（`src/llvm-project` は checkout すら不要）。`llvm_cmake_dir` は
`<llvm-config のあるディレクトリ>/../lib/cmake/llvm` と決め打ちで計算されます。

同時に `config.rs::is_system_llvm()` が真、`llvm-has-rust-patches` を書かなければ
`is_rust_llvm()` は「rust-lang のパッチは無い」と解釈し、`compile.rs` は
`LLVM_RUSTLLVM` を**定義しません**（＝ patched LLVM 前提のコードパスを使わない）。
`llvm-has-rust-patches = false` を明示しているのはこの意図を固定するためです。

### 2.2 バージョンチェックは major だけ

```rust
let mut parts = version.split('.').take(2).filter_map(|s| s.parse::<u32>().ok());
if let (Some(major), Some(_minor)) = (parts.next(), parts.next()) && major >= 20 { return; }
panic!("bad LLVM version: {version}, need >=20");
```

21.1.6 は通ります。**ここが「黙って通ってしまう」箇所**なので、実際に使われた
ことは別途証明します（§5）。

### 2.3 `rustc_llvm` がリンク時に要求するもの

`compiler/rustc_llvm/build.rs`（1.94.0）:

| 呼び出し | 要求 |
| --- | --- |
| `--version` | 表示・記録用 |
| `--components` | `REQUIRED_COMPONENTS`（`ipo bitreader bitwriter linker asmparser lto coverage instrumentation`）を含むこと |
| `--link-static --libs` | 静的ライブラリ名の一覧。`.a` のフルパスなら `rustc-link-search` + 名前、`-lNAME` なら名前のみ |
| `--cxxflags` | C++ ラッパ（`llvm-wrapper`）のコンパイル。`-I` は `-I<prefix>/include` に置換される |
| `--system-libs` | cross でない場合のみ。iOS では SDK 側の libz 等を使うので空 |
| `--host-target` | `target != host` の判定。iOS 用は `aarch64-apple-ios` を返す |
| `--libdir` / `--has-rtti` / `--build-mode` / `--assertion-mode` | 情報系 |

darwin では C++ ランタイムとして `c++`（libc++）をリンクします。

### 2.4 ビルド設定

| 設定 | 値 | 理由 |
| --- | --- | --- |
| `[llvm] download-ci-llvm` | `false` | 配布 LLVM は macOS 用で、iOS 用 rustc には使えない |
| `[llvm] link-shared` | `false` | 静的ライブラリをリンク（`LLVM_LINK_SHARED` を立てない） |
| `[llvm] targets` | `AArch64` | 外部 LLVM を使う場合は未使用（bootstrap が LLVM をビルドしないため） |
| `[rust] llvm-tools` | `false` | 外部 LLVM に llvm-tools は無い。必要な `llvm-ar` 等は `SwiftLLVM/ios/bin` に同梱 |
| `[build] build` | `aarch64-apple-darwin` | ビルドマシン |
| `[target."aarch64-apple-darwin"]` | `llvm-config = <SwiftLLVM>/macosx/bin/llvm-config` | stage1 rustc（macOS で動く）用 |
| `[target."aarch64-apple-ios"]` | `llvm-config = <SwiftLLVM>/ios/bin/llvm-config` | 出荷する rustc 用 |

`patch_bootstrap_llvm()`（iOS 向けに LLVM をクロスビルドさせるパッチ）は
`RUST_LLVM_MODE=swift` では**実行しません**。LLVM をビルドするコードパス自体が
動かないためです（`intree` モードでのみ適用）。

---

### 2.5 rust-lang 版 LLVM との API 差（パッチで吸収）

major.minor が同じでも、rust-lang/llvm-project の `rustc/21.1-2025-08-01` と
swiftlang/llvm-project の `swift-6.4.0-RELEASE` は別のコミットです。rustc の
C++ ラッパーが LLVM を**バージョン番号だけで**分岐している箇所は、upstream 側の
API 変更がそのままコンパイルエラーになります（実ビルドで 1 件検出）。

| 箇所 | rust-lang 版 (21.1.8) | swiftlang 版 (21.1.6) | 対応 |
| --- | --- | --- | --- |
| `llvm::PGOOptions` のコンストラクタ | 第 5 引数に `IntrusiveRefCntPtr<vfs::FileSystem>` | **無い**（upstream が 21.1.6 より前に削除） | `patches/0001-rustc-1.94.0-pgooptions-without-vfs.patch` で `FS` を渡さない形にそろえる（rustc は LLVM 22 まで「ある」前提で分岐している） |

パッチは `fetch` と `configure` が自動で当てます（`git apply`、当たらない場合は
**失敗**させます。無理に押し通さない）。`RUST_LLVM_MODE=intree` では当てません。
理由は各パッチのヘッダにも書いてあります。

## 3. Swift 側の LLVM

`Scripts/swift-ios-toolchain-presets.ini` は emexlab/LLVM-On-iOS の
`nyxian_iphoneos_arm64_crosscompiler` を元にしたプリセットで、LLVM を 2 回
ビルドします（同じソース、同じターゲット構成）。

`llvm-targets-to-build=AArch64;ARM;X86` です。rustc と iOS の Swift が使うのは
AArch64 だけですが、compiler-rt は runtimes の一部として `macho_embedded` 向け
builtins を armv6m / armv7m / armv7em（ARM）と i386 / x86_64（X86）について
ビルドします。ARM バックエンドが登録する `-arm-add-build-attributes` を clang が
使うため、ARM を外すとそのステップが
`Unknown command line argument '-arm-add-build-attributes'` で失敗します
（CI で確認）。反対に LLVM 既定の全ターゲットでは 1 回のビルドが 6 時間の
ジョブ上限に収まらなかったため（実測 約 5 時間 45 分でタイムアウト）、
必要な 3 つに絞っています。

| 出力 | 用途 |
| --- | --- |
| `llvm-macosx-arm64` | macOS 上で動くツール（Swift コンパイラ本体、tablegen、llvm-config） |
| `llvm-iphoneos-arm64` | iOS 上で動く LLVM（**Rust がリンクするのはこちら**） |

Rust と噛み合わせるために意識している設定:

- `-DLLVM_ENABLE_RTTI:BOOL=ON` — swift のプリセット通り。`--has-rtti` が `YES` になり、
  `-fno-rtti` が cxxflags に混ざらない（rustc_llvm のラッパも同じ設定でコンパイルされる）。
- `-DLLVM_ENABLE_ASSERTIONS=OFF` / `release` — 最適化ビルド同士で揃える。
- `-DLLVM_ENABLE_EH:BOOL=OFF` — Rust 側も例外を使わない。
- `cross-compile-hosts=iphoneos-arm64` — **Swift も LLVM も iOS/arm64 バイナリ**に
  なる（macOS 用の成果物を iOS と称さないための大前提）。

`install_llvm` は CMake のビルドツリーから「インストール済みの形」を組み立てます。

```
work/SwiftLLVM/macosx/{bin/llvm-config, include/, lib/*.a}
work/SwiftLLVM/ios/   {bin/{llvm-config,llvm-ar,…}, include/, lib/*.a}
```

ヘッダは **ソースツリーの `llvm/include` ＋ ビルドツリーの生成ヘッダ**
（`llvm/Config/llvm-config.h` など）を重ねて作ります。ビルドツリーだけには
公開ヘッダが無く、ソースツリーだけには `llvm-config.h` が無いためです。

### なぜ `llvm-config` を生成するのか

- iOS 用 `llvm-config` は **iOS バイナリ**で、macOS 上では実行できません。
- `rustc_llvm/build.rs` はビルド中に `llvm-config` を**実行**します。
- ビルドツリー自体（数十 GB）は成果物として持ち回れません。

そこで `Scripts/llvm-config-shim.py` が、実物の `llvm-config` の回答
（version / components / libs / cxxflags / system-libs / host-target）を
取り込み、**自分の位置からパスを解決する POSIX sh** を書き出します。
ツリーごと移動しても動くので、CI の artifact として別ジョブに渡せます。

```
$ work/SwiftLLVM/ios/bin/llvm-config --version
21.1.6
$ work/SwiftLLVM/ios/bin/llvm-config --link-static --libs | tr ' ' '\n' | head -3
LLVMCore
LLVMSupport
...
```

shim は呼ばれるたびに `<prefix>/llvm-config.log` に引数を記録します。
これは「Rust のビルドが本当にこの LLVM を使った」証拠としてそのまま提出できます。

| mode | `--host-target` | `--system-libs` | 使う場面 |
| --- | --- | --- | --- |
| host | `aarch64-apple-darwin` | macOS のものをそのまま | stage1 rustc（ビルドマシン用） |
| ios | `aarch64-apple-ios` | 空（SDK の libz 等を使う） | 出荷する rustc（iOS 用） |

---

## 4. 何が変わったか

| ファイル | 変更 |
| --- | --- |
| `Scripts/build-swift-toolchain.sh` | 新規。Swift 6.4 + LLVM 21.1.6 を iOS 向けにビルドし、`SwiftLLVM/{macosx,ios}` と `SwiftToolchain` を作る |
| `Scripts/swift-ios-toolchain-presets.ini` | 新規。LLVM-On-iOS 相当のプリセット（RTTI 有効、AArch64 のみ、iOS 16.0） |
| `Scripts/llvm-config-shim.py` | 新規。再配置可能な `llvm-config` の生成 |
| `Scripts/build-rust-toolchain.sh` | `RUST_LLVM_MODE=swift` を追加。`bootstrap.toml` に `[target.*] llvm-config` と `llvm-has-rust-patches=false` を書き、`src/llvm-project` を fetch せず、`llvm-tools=false` にし、`verify` で LLVM の出所を証明する。既定 `RUST_VERSION=1.94.0` |
| `.github/workflows/build-rust-ios.yml` | `swift` ジョブ（Swift + LLVM）→ `build` ジョブ（Rust）の 2 段構成。LLVM のキャッシュを廃止し、`SwiftLLVM` artifact で受け渡す |
| `Makefile` | `make llvm` / `make swift` を追加、`RUST_VERSION=1.94.0`、`RUST_LLVM_MODE=swift` |
| `Scripts/build-rust-toolchain.sh`（パッケージ） | `RustSupportLibs` を廃止し、`RustToolchain`（コンパイラのみ）と `RustStd`（std のみ）に分割 |

Rust のビルドで LLVM 用に残っているのは次の 2 つだけで、どちらも
「LLVM を作らない」方向の変更です。

1. `src/llvm-project` をサブモジュールとして取得しない（`library/backtrace` のみ）。
2. `patch_bootstrap_llvm` を適用しない（`intree` モードのみ）。

---

## 5. 「Swift の LLVM を使った」ことの証明

`Scripts/build-rust-toolchain.sh verify` の `verify_llvm_source()` が、
**ビルドログではなくビルドの生成物**から 3 点を確認します。1 つでも欠ければ
`verify` は失敗します（`die`）。

1. **設定**: `rust-source/bootstrap.toml` の
   `[target."aarch64-apple-ios"] llvm-config` が `work/SwiftLLVM/ios/bin/llvm-config`、
   `[target."aarch64-apple-darwin"]` が `…/macosx/bin/llvm-config` を指している。
2. **LLVM をビルドしていない**: `build/aarch64-apple-{darwin,ios}/llvm/build` が
   存在しない（bootstrap が LLVM を configure していない）。
3. **rustc_llvm のリンク先**: `build/**/rustc_llvm-*/output` に
   `cargo:rustc-link-search=native=<SwiftLLVM>/…` が記録されている。
   これは cargo がそのまま `rustc_llvm` のリンク行に使う値で、
   **コンパイラに入る LLVM そのもの**です。

加えて shim の `llvm-config.log` に、bootstrap が実際に呼んだ引数が残ります。

```
$ cat work/SwiftLLVM/ios/llvm-config.log
2026-…Z --version
2026-…Z --libdir
2026-…Z --host-target
2026-…Z --link-static --libs
```

CI では `verify` が失敗したとき、bootstrap.toml・`llvm-config.log`・
ディレクトリ一覧を `build.log` に落とし、PR コメントに出します。

### 5.1 ビルド前の `preflight`（数秒で落とす）

`Scripts/build-rust-toolchain.sh preflight` は、`build` の**前**に「その LLVM を
実際にリンクできるか」を数秒で確認します。ここで検出するものは、放っておくと
**2 段のコンパイラビルドが終わった後のリンクエラー**としてしか現れません。

* macOS 版と iOS 版の `llvm-config` が同じバージョンを返すか
* `ios/include/llvm/Config/llvm-config.h` があり、`--version` と major が一致するか
  （Swift の `PACKAGE_VERSION` のため patch は一致しない。§1 参照）
* iOS の `llvm-config --link-static --libs` が `-l<name>` を出さないか。
  shim のライブラリ一覧は macOS 側の `llvm-config` から作るので、iOS スライスに
  無いライブラリは「パスではなく `-l`」として現れる
* `ios/lib` のアーカイブが本当に iOS か（`__.SYMDEF` を飛ばして実メンバーを検査、
  `macosx/lib` 側が macOS か）
* `ios/bin/llvm-ar` があるか（無いと端末上の rustc がアーカイブを作れない）

`configure` の最後と、CI の「Unpack the shared LLVM」ステップで実行します。

ローカルで確認できること（macOS 不要・スタブで実行可能）:

```bash
# 生成した shim が期待通りに答えるか
Scripts/llvm-config-shim.py --source /path/to/real/llvm-config --mode ios \
    --host-target aarch64-apple-ios --out /tmp/x/bin/llvm-config
/tmp/x/bin/llvm-config --version --libdir --libs --cxxflags

# preflight（偽の SwiftLLVM ツリーでも可。無い場合は configure が先に落ちる）
SWIFT_LLVM_DIR=/tmp/x     ARTIFACTS_DIR=/tmp/artifacts RUST_SOURCE_DIR=/tmp/rust-src \
    Scripts/build-rust-toolchain.sh preflight
```

---

## 6. 未検証・リスク（実装済みと混同しないこと）

| 項目 | 状態 |
| --- | --- |
| `bootstrap.toml` の生成、`src/llvm-project` を fetch しないこと、`patch_bootstrap_llvm` を適用しないこと | **実装済み・ローカルで確認済み**（スタブ環境） |
| `verify_llvm_source()` の 3 チェック | **実装済み・ローカルで確認済み**（成功/失敗の両方） |
| `llvm-config` shim の回答と再配置 | **CI で確認済み**（ホスト/iOS 両方の shim が LLVM 21.1.6 を報告、96 MB の artifact として受け渡し） |
| Swift 6.4 の iOS ビルド（LLVM 2 種 + swift-frontend） | **CI で成功**（4 時間 21 分、`swift-frontend` は iOS/arm64） |
| `swiftc`（ドライバ）の iOS 性 | **未確認／おそらくホスト用**: 直近の実行で macOS バイナリと判定。`swift-frontend` が iOS なのでコンパイラとしては成立するが、ドライバをデバイスで使うには追加対応が要る |
| Swift ツールチェーンに混ざるホスト（macOS）バイナリ | **既知**: LLVM-On-iOS も `lib/swift/host/compiler/*.dylib` を同梱。`verify` は内訳をレポートし、iOS と偽らない |
| 静的ライブラリの iOS 性 | **実装**: シンボルテーブル（`__.SYMDEF`）を除いたメンバー（`.o`）を抽出して `vtool` で `platform IOS` を確認（`file` では ar archive としか出ないため）。実アーカイブでの確認は次回実行 |
| Rust 1.94.0 が LLVM 21.1.6 でリンク・動作すること | **未検証**。このワークフローで初めて実行する |
| rust-lang/llvm-project 固有パッチの全列挙 | **未完了**。`rustc/21.1-2025-08-01` は upstream `release/21.x` のマージが主で、bootstrap 側の分岐は `LLVM_RUSTLLVM` の定義だけ。ただし「1 つも無い」ことまでは確認できていない |
| 21.1.6 と 21.1.8 の差 | **patch のみ**（`release/21.x`）。C++ API の互換性は同一と判断しているが、実際のコンパイルで確認する |
| `LLVM_ENABLE_RTTI=ON` と rustc_llvm の組み合わせ | プリセット側で ON、shim の `--has-rtti` も `YES`。実ビルドでの確認は未 |
| rust-lang 版 LLVM との API 差 | **2 件検出・パッチ適用**（`PGOOptions` の vfs 引数、`stdc++`→`libc++`）。他にも同種の差があれば実ビルドで判明する |
| 静的 `Rust.xcframework`（`libRustCompiler.a`） | **継続中**: `librustc_driver_impl` の rlib は見つかる。`derive_where`（proc-macro）の解決で 2 回失敗（E0463 → 探索範囲を広げすぎて E0514: stage0 の 1.93 ビルド版を掴んだ）。stage2 のグラフだけを探索するよう修正し、次回実行で確認する。今は静的リンクに失敗すると dylib にフォールバックし、理由を REPORT.txt に残す |
| `preflight`（ビルド前の数十秒チェック） | **実装済み・スタブで確認済み**: 成功経路、iOS 側のライブラリ欠落、macOS アーカイブの混入、`RUST_LLVM_MODE=intree` の各経路。実アーカイブでの確認は次回実行 |
| ビルド時間 | Swift 4 h 29 m（実測）。Rust は stage1 + stage2 の 2 回で、ジョブ上限はランナー最大の 6 h に拡大した。**Rust 側の実測はまだ無い** |

既知の割り切り:

- **macOS 用 LLVM も Swift のビルド成果物から取ります。** 別の LLVM を作らないためで、
  rust-lang 版との混在はありません。
- `llvm-tools`（`llvm-ar` 等）は Swift のビルド成果物（iOS バイナリ）を
  `SwiftLLVM/ios/bin` に置いて使います。bootstrap には `llvm-tools = false` を渡します。
- `SwiftLLVM` artifact は macOS/iOS 両方の静的ライブラリを含みます（実測 96 MB）。
  これは「LLVM を 2 回ビルドしない」ための必要経費です。
- **Swift ツールチェーンにはホスト（macOS）バイナリが混ざります。** `lib/swift/host/`
  など、Swift のクロスビルドが常に出すものです（LLVM-On-iOS も同梱）。iOS と
  称するのは `swift-frontend` / 静的ライブラリ / `SwiftLLVM` で、混入物は
  `verify` が一覧と件数をレポートに残します。

---

## 7. 参考: 手元で確認するコマンド

```bash
# バージョンの突き合わせ
grep -E "set\(LLVM_VERSION" swift-source/llvm-project/cmake/Modules/LLVMVersion.cmake
grep -E "set\(LLVM_VERSION" rust-source/src/llvm-project/cmake/Modules/LLVMVersion.cmake

# Rust がどの LLVM を指しているか
grep -A2 'llvm-config' rust-source/bootstrap.toml

# 実際に LLVM をビルドしていないこと
ls rust-source/build/*/llvm/build 2>/dev/null && echo "LLVM was built!" || echo "no in-tree LLVM"

# rustc_llvm のリンク先
grep -r "rustc-link-search" rust-source/build/*/stage*/release/build/rustc_llvm-*/output
```
