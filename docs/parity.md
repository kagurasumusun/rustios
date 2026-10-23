# Swift と Rust の成果物・ビルド構成の対応（parity）

このリポジトリの製品は「1 つの LLVM を共有する 2 つの iOS コンパイラ」です。
Swift 側の成果物は [emexlab/LLVM-On-iOS](https://github.com/emexlab/LLVM-On-iOS)
と**同じ名前・同じ形式・同じ中身の構成**で、Rust 側の成果物はそれと
**1 対 1 で対応する構造**にしています。ビルド構成（フラグ）も、両者が
同じ値になるように合わせ、ずらす場合は理由を記録します。

- Swift 側: `Scripts/build-swift-toolchain.sh` + `Scripts/swift-ios-toolchain-presets.ini`
- Rust 側: `Scripts/build-rust-toolchain.sh`（`bootstrap.toml` を生成）
- 共有 LLVM の仕組み: [llvm-sharing.md](llvm-sharing.md)

---

## 1. 成果物の対応表

| 役割 | LLVM-On-iOS（Swift） | rustios（Rust） | 中身の対応 |
| --- | --- | --- | --- |
| デバイス上で動くコンパイラ本体 | `SwiftToolchain.zip` → `SwiftToolchain/usr/{bin,include,lib,share}` | `RustToolchain.zip` → `RustToolchain/usr/{bin,include,lib}` | bin = コンパイラドライバ（swiftc/swift-frontend ↔ rustc/rustdoc）＋**同一の LLVM コンポーネントツール**（clang, lld, llvm-ar, llvm-nm, llvm-ranlib, llvm-cov, llvm-profdata, llvm-objdump, llvm-objcopy, llvm-symbolizer）。include = コンパイラの C ヘッダ（swift/clang/llvm ヘッダ ↔ `rustios.h`）。lib = 実行時に必要なライブラリ（lib/swift/... ↔ librustc_driver dylib + rustlib/...） |
| アプリに埋め込む静的コンパイラ | `LLVM.xcframework` → `ios-arm64/llvm.a` + `Headers/` | `Rust.xcframework` → `ios-arm64/rust.a` + `Headers/` | `llvm.a` = libtool で結合した libswift\*.a + libclang\*.a + liblld\*.a + libLLVM\*.a + cmark。`rust.a` = rustc 本体（staticlib）＋**同じ共有 LLVM のアーカイブ**を結合したもの。どちらも「コンパイラスタック全体を 1 本の .a + ヘッダ」にした xcframework |
| 実行時サポート dylib | `CoreCompilerSupportLibs/` → `lib_Compiler*.dylib`（`lib/swift/host/compiler/` のコピー） | `RustSupportLibs/` → `librustc_driver-*.dylib` + `libstd-*.dylib` + `codegen-backends/*.dylib`（`RustToolchain/usr/lib` のコピー） | 「埋め込みコンパイラが実行時にロードする dylib」をフラットに束ねたもの。原本はツールチェーン本体に残る（コピーである点も同じ） |
| 共有 LLVM（rustios 追加） | （対応物なし — Rust をビルドしないため不要） | `SwiftLLVM.tar.xz` → `SwiftLLVM/{macosx,ios}/{bin,include,lib}` | Rust のビルドジョブへ LLVM を渡すための再配置可能インストール形。`bin/llvm-config` は shim（[llvm-sharing.md §3](llvm-sharing.md)） |
| ターゲット std（rustios 追加） | （対応物なし — Swift のプリセットは stdlib をビルドしない。iOS は OS 内蔵の Swift ランタイムを使う） | `RustStd.tar.xz` → `RustStd/usr/lib/rustlib/aarch64-apple-ios/lib/*.rlib` | Rust には OS 提供の std が存在しないため、Swift 側の「stdlib をビルドしない」判断の隙間を埋める成果物 |
| チェックサム | （なし） | `SHA256SUMS.txt`（全成果物） | rustios 追加 |

### 形式・名前を揃えた点

* Swift 側の 3 点は LLVM-On-iOS と**同名**です（`SwiftToolchain.zip` は zip 形式、
  内部レイアウト `SwiftToolchain/usr/...`、ドライバ symlink の materialize 対象
  （swift, swiftc, clang, clang++, clang-cpp）まで同じ）。CI 転送用の
  `.tar.xz` ラッパ（`LLVM.xcframework.tar.xz`、`CoreCompilerSupportLibs.tar.xz`）は
  LLVM-On-iOS の CI が `CoreCompilerSupportLibs.tar.xz` を作るのと同じ做法です。
* Rust 側はバージョン/プラットフォーム接尾辞を付けず、Swift 側と同名規則に
  揃えました（バージョンは `build-info.json` / `REPORT.txt` / `SHA256SUMS.txt` と
  リリースタグが持ちます）。
* `Rust.xcframework` の静的アーカイブ名は `rust.a`。`LLVM.xcframework` の
  `llvm.a` に対する 1 対 1 の命名です。

### 検証（成果物レベル）

`verify` / `package` は次を機械的に確認し、1 つでも欠ければ失敗します。

1. **iOS 専用**（両側）: 出荷ツリーの全 Mach-O が arm64 かつ `platform IOS`
   （`assert_ios_only`、`vtool -show-build`）。
2. **コンポーネントツールの一致**（両側）: プリセットの
   `llvm-install-components` 行からツール一覧を**パース**し
   （`llvm_component_tools()`）、`SwiftToolchain/usr/bin`・`SwiftLLVM/{macosx,ios}/bin`・
   `RustToolchain/usr/bin` のすべてに揃っていることを確認
   （`verify_component_tools`）。一覧の唯一の出所がプリセットなので、
   Swift と Rust が違うツールセットを shipped することは構造上できません。
3. **llvm.a の構成**（Swift 側）: `libLLVM*.a` を含まない結合入力は拒否。
   実際に何が入ったか（カテゴリ別カウント）を `REPORT.txt` に記録。
4. **rust.a の C API とリンク**（Rust 側）: `rustios_run`/`rustios_version` の
   エクスポート確認＋ arm64/iOS のテストプログラムを実際に clang でリンク
   （`link_check_static`）。

---

## 2. ビルド構成（フラグ）の対応表

Swift 側は LLVM-On-iOS の `nyxian_iphoneos_arm64_crosscompiler` プリセット
（ほぼ同一 — 差分は §3）、Rust 側は `Scripts/build-rust-toolchain.sh configure`
が書く `bootstrap.toml`。**同じ LLVM を共有する**ため、LLVM に関する構成は
「両方で同じバイナリ」＝最強の形で一致します。それ以外の一対一対応:

| 性質 | Swift プリセット | Rust `bootstrap.toml` / 環境 | 一致 |
| --- | --- | --- | --- |
| LLVM ソース | swiftlang/llvm-project（`swift-6.4.0-RELEASE` の update-checkout） | `[target.*] llvm-config = SwiftLLVM/{macosx,ios}/bin/llvm-config`（同じビルド成果物） | ✅ 同一ビルド |
| LLVM バージョン | 21.1.6 | 要件 ≥ 20（bootstrap のチェック）、実際は 21.1.6（`build-info.json` に記録） | ✅ |
| LLVM ターゲット | `llvm-targets-to-build=AArch64;ARM;X86` | `[llvm] targets = "AArch64;ARM;X86"`（intree モード時のみ実効。swift モードでは `--targets-built` が同じ値を報告し `build-info.json` に記録） | ✅ 同値 |
| ビルドタイプ | `release` | `[llvm] optimize = true`、`[rust] optimize = true` | ✅ |
| アサーション | `no-assertions` 系 + `LLVM_ENABLE_ASSERTIONS=OFF` | `[llvm] assertions = false`（debug-assertions も off） | ✅ |
| RTTI | `LLVM_ENABLE_RTTI=ON` | `llvm-config --has-rtti` = YES を rustc_llvm が採用（`--cxxflags` に `-fno-rtti` が混ざらない） | ✅ 共有 LLVM により強制一致 |
| 例外 | `LLVM_ENABLE_EH=OFF` | LLVM 既定 OFF（bootstrap は有効化しない） | ✅ |
| zstd | `LLVM_ENABLE_ZSTD=OFF` | `[llvm] libzstd = false` | ✅ |
| zlib | `LLVM_ENABLE_ZLIB=OFF`（rustios 差分、§3） | bootstrap 自身も apple-ios の in-tree LLVM で `LLVM_ENABLE_ZLIB=OFF` を強制（"Zlib fails to link properly"） | ✅ |
| terminfo | `LLVM_ENABLE_TERMINFO=OFF`（rustios 差分、§3） | 共有 LLVM に含まれない（リンク時に余計な system lib が増えない） | ✅ |
| backtraces | `LLVM_ENABLE_BACKTRACES=OFF` | 共有 LLVM の設定がそのまま効く | ✅ |
| テスト | `BUILD_TESTING=OFF`、`llvm-include-tests=0`、`swift-include-tests=0` | `[llvm] tests = false` | ✅ |
| ベンチマーク | `skip-build-benchmarks` | bootstrap 既定 `LLVM_INCLUDE_BENCHMARKS=OFF` | ✅ |
| ツールチェーンのみ | `build-toolchain-only=1` | `extended = false`（cargo/rust-analyzer 等をビルドしない） | ✅ |
| stdlib | `build-swift-{static,dynamic}-stdlib=0`、`build-stdlib-deployment-targets=`（空） | std はビルドするが `RustStd` として別配布（OS 内蔵 Swift ランタイムに相当するものが Rust には無いため） | ⚠️ 意図的差分 |
| deployment target | `darwin-deployment-version-ios=16.0` | `IPHONEOS_DEPLOYMENT_TARGET=16.0` を export、`vtool` で `minos 16.0` を検証 | ✅ |
| ホスト/クロス | `host-target=macosx-arm64` + `cross-compile-hosts=iphoneos-arm64` | `build = "aarch64-apple-darwin"`、`host = target = ["aarch64-apple-ios"]` | ✅ |
| インストール部品 | `llvm-install-components=llvm-ar;...;clang;...;lld` | 同じ行をパースしたツール群を `SwiftLLVM/*/bin` と `RustToolchain/usr/bin` に配置（§1 の検証 2） | ✅ 同一出所 |
| 静的リンク | 静的 .a（`llvm.a` に結合） | `[llvm] link-shared = false` | ✅ |
| ビルドシステム | ninja（build-script） | `[llvm] ninja = true` | ✅ |
| reconfigure | `reconfigure`（毎回 CMake を再実行） | `configure` が毎回 `bootstrap.toml` を再生成 | ✅ |
| コンパイラキャッシュ | （なし） | sccache/ccache があれば使用（CI では無効、§3） | ⚠️ rustios 追加 |

`build-info.json`（各 Rust 成果物に同梱）には、共有 LLVM の `llvm-config` から
読み戻した `llvm_version` / `llvm_targets_built` / `llvm_build_mode` /
`llvm_assertion_mode` / `llvm_has_rtti` を記録します。表の「一致」は
見た目ではなく、ビルドに使われた設定そのものから検証できます。

---

## 3. LLVM-On-iOS からの意図的差分（すべて記録済み）

Swift 側のビルドは LLVM-On-iOS と同一を目標としますが、次の 3 点だけ
プリセットが異なります。**いずれも「共有 LLVM を Rust がリンクできる」
ための必要条件**で、CI 実測またはソース根拠があります。

| 差分 | LLVM-On-iOS | rustios | 理由（根拠） |
| --- | --- | --- | --- |
| `llvm-targets-to-build` | 指定なし（LLVM 既定 = 全ターゲット） | `AArch64;ARM;X86` | 全ターゲットは GitHub  hosted macOS ランナーの 6 時間制限に収まらない（実測 約 5 h 45 m でタイムアウト）。AArch64 単独は compiler-rt の macho_embedded builtins（armv6m/armv7m/armv7em, i386/x86_64）が ARM/X86 バックエンドを要求して失敗（CI で `Unknown command line argument '-arm-add-build-attributes'` を確認）。出荷コンパイラが狙うのは arm64-apple-ios のみで、3 ターゲットで機能は変わらない |
| `-DLLVM_ENABLE_ZLIB=OFF` | 指定なし（既定 ON） | OFF | rustc_llvm/build.rs はクロスビルド時 `--system-libs` を**リンクしない**（"Don't link system libs if cross-compiling"）。zlib ON の LLVM アーカイブは libz シンボルが未解決のまま iOS rustc のリンクに渡る。Rust 公式 bootstrap 自体も apple-ios の in-tree LLVM で `LLVM_ENABLE_ZLIB=OFF` を強制している（llvm.rs: "Zlib fails to link properly"） |
| `-DLLVM_ENABLE_TERMINFO=OFF` | 指定なし（既定 ON） | OFF | 同上。terminfo/curses 系シンボルが iOS リンクで未解決になるのを防ぐ |

CI 実運用上の差分（成果物の中身には影響しません）:

* 成果物はリポジトリ直下ではなく `artifacts/` に集め、`SHA256SUMS.txt` と
  `REPORT.txt` を付ける（LLVM-On-iOS の CI は成果物をアップロードしていない
  步骤があり、rustios は全成果物を `if-no-files-found: error` で保証する）。
* `LLVM.xcframework` と `CoreCompilerSupportLibs` は CI 転送用に `.tar.xz`
  へ包む（LLVM-On-iOS の CI も `CoreCompilerSupportLibs.tar.xz` を作る）。
* `install-nyxian`（Nyxian IDE への展開）に相当するステップは無い
  （展開先リポジトリが存在しないため）。
* sccache は使わない（GitHub Actions バックエンドの一時的ストレージエラーで
  コンパイルが落ちるため。CI 履歴で確認）。

---

## 4. 対応の検証方法（コマンド）

```bash
# 1. ツールセットの一致（唯一の出所 = プリセットの llvm-install-components）
#    macOS でビルド後、一覧と両ツールチェーンの bin を突き合わせる
#    （verify/package 内の verify_component_tools が自動で実施するものと同じ）
tools=$(sed -n 's/^llvm-install-components=//p' Scripts/swift-ios-toolchain-presets.ini \
        | tr ';' '\n' | grep -E '^(clang|lld|llvm-[a-z0-9-]+)$')
for t in $tools; do
    ls work/SwiftToolchain/usr/bin/"$t" work/RustToolchain/usr/bin/"$t"
done

# 2. LLVM ターゲットの一致
Scripts/build-swift-toolchain.sh info | grep 'llvm targets'
grep -n 'targets' rust-source/bootstrap.toml
work/SwiftLLVM/ios/bin/llvm-config --targets-built

# 3. 成果物レイアウトの一致
unzip -l artifacts/SwiftToolchain.zip | head        # SwiftToolchain/usr/bin/swiftc ...
unzip -l artifacts/RustToolchain.zip | head         # RustToolchain/usr/bin/rustc ...
tar -tJf artifacts/LLVM.xcframework.tar.xz | head   # .../ios-arm64/llvm.a + Headers/
tar -tJf artifacts/Rust.xcframework.tar.xz | head   # .../ios-arm64/rust.a + Headers/
tar -tJf artifacts/CoreCompilerSupportLibs.tar.xz   # lib_Compiler*.dylib
tar -tJf artifacts/RustSupportLibs.tar.xz           # librustc_driver-*.dylib ...

# 4. Rust が Swift の LLVM を使った証明（llvm-sharing.md §5）
Scripts/build-rust-toolchain.sh verify
cat work/SwiftLLVM/ios/llvm-config.log
```

## 5. 検証ステータス

| 項目 | 状態 |
| --- | --- |
| 成果物名・形式・内部レイアウトの対応（§1） | **実装済み**。スクリプトと CI のステップを一致させた。実ビルドでの確認は CI 実行待ち |
| コンポーネントツールの一致チェック（`verify_component_tools`） | **実装済み**（ローカルでスタブ検証）。CI 実行待ち |
| フラグ対応表（§2）の値の一致 | **実装済み**（bootstrap.toml / プリセット / Makefile の既定値を同値に）。`build-info.json` が実ビルド値を記録 |
| llvm.a の LLVM-On-iOS 同一構成（libswift\* + libclang\* + liblld\* + libLLVM\* + cmark + Headers 結合順） | **実装済み**。中間インストールに静的ライブラリが無い場合はビルドツリーから補完し、REPORT に記録。実ビルドでの確認は CI 実行待ち |
| rust.a（旧 libRustCompiler.a）のリネーム | **実装済み**。リンクテスト（`link_check_static`）が CI で再実行される |
| Swift stdlib をビルドしない / Rust std は別配布 | **意図的差分**（§2）。根拠は iOS の OS 内蔵 Swift ランタイム |
