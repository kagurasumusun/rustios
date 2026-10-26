# Swift の LLVM を共有しても、どちらのコンパイラも機能を失わないこと

rustios の目標は「**1 つの LLVM** から、iOS で動く Swift コンパイラと iOS で動く
Rust コンパイラを作る」ことです（[llvm-sharing.md](llvm-sharing.md)）。
この文書は、そのときに **Swift 側の LLVM ビルド設定を Rust 側の要求に合わせる**
（＝ Rust が自前で LLVM をビルドした場合と機能差を出さない）ために何を揃えたか、
揃えられないものをどう扱ったかを記録します。

対象は LLVM の**ビルド構成**と、Rust のビルド構成のうち「成果物の性能・機能に
効くもの」です。`macOS` はビルド用ホストで、成果物は iOS のみです。

---

## 1. 共有 LLVM が Rust に提供しなければならないもの

rustc は LLVM を「リンクするライブラリ」としてだけでなく、**ビルド時に道具として**
使います。足りないと、ビルドが失敗するか、静かに機能が落ちます。

| 必要なもの | 誰が使うか | 無いとどうなるか | rustios の対応 |
| --- | --- | --- | --- |
| iOS の静的ライブラリ一式 (`lib/*.a`) | rustc のリンク（`rustc_llvm`） | リンクできない | Swift の iOS ビルド成果物をそのまま `SwiftLLVM/ios/lib` に置く |
| ヘッダ (`include/`, 生成物含む) | `rustc_llvm` の C++ ラッパーのコンパイル | ビルドできない | `llvm-config --includedir` と `llvm-config.h` を確認 |
| `llvm-config`（ホストで動く） | bootstrap と `rustc_llvm` | ビルドできない | `Scripts/llvm-config-shim.py` が再配置可能な POSIX sh を生成 |
| **`LLVM_TOOLS` の 14 個** (`llvm-ar`, `llvm-objcopy`, `llvm-profdata`, `llc`, `opt`, …) | bootstrap が `lib/rustlib/<host>/bin` に導入し、端末上の rustc が `llvm-ar`/`rust-objcopy` として使う | `lib/rustlib/<host>/bin` が空になり、端末で静的ライブラリを作れない・`-C strip` が効かない | Swift 側のインストールで 14 個 + `llvm-ranlib` を両ツリー（macOS/iOS）に入れる。Rust 側は揃っている時だけ `llvm-tools = true` |
| `compiler-rt` のソース | `compiler-builtins` の C 実装 (`compiler-builtins-c`) | 純 Rust の組み込み実装にフォールバックし、`memcpy` などが遅くなる（公式ツールチェーンとの差） | 共有 LLVM と**同じ llvm-project コミット**から `compiler-rt/lib/builtins` を取る |
| `FileCheck`（ビルド機用） | `x.py test` の codegen テスト | `codegen-tests = true` にできない | macOS ツリーにあれば入れて `codegen-tests = true`、無ければ false とレポート |
| コンポーネント情報 (`llvm-config --components`) | `rustc_llvm` が必須コンポーネントの有無を検査 | ビルドが panic | シムがホストの答えをそのまま返す |

`LLVM_TOOLS` の一覧は `src/bootstrap/src/lib.rs` の定数で、bootstrap は
`Sysroot` ステップで `llvm-config --bindir` の隣からこれをコピーします
（`compile.rs`）。外部 LLVM の場合は「`llvm-config` と同じディレクトリ」を
使う実装なので、`SwiftLLVM/{macosx,ios}/bin` に置けばそのまま入ります。

> 以前の rustios は 5 個 (`llvm-ar`/`llvm-nm`/`llvm-ranlib`/`llvm-objcopy`/
> `llvm-strip`) しか入れておらず、`llvm-tools = false` でこの仕組みごと
> 切っていました。結果として配布物に `lib/rustlib/aarch64-apple-ios/bin` が
> 無く、**端末上の rustc は `ar` を要求する**状態でした。現在は 14 個を
> 入れ、`llvm-tools = true` で公式と同じ配置にしています。

---

## 2. LLVM の CMake 構成: Rust の参照ビルドとの比較

「Rust の参照ビルド」= rust-lang/rust 1.94.0 の
`src/bootstrap/src/core/build_steps/llvm.rs` が `x.py build` で渡す `-D` の集合
（`bootstrap.toml` の既定値、対象は `aarch64-apple-ios`）。
「Swift の参照ビルド」= このプリセットから `-DLLVM_ENABLE_*` を外したもの、
つまり Swift の既定（`utils/build_swift` の `--llvm-targets-to-build` 既定値と
LLVM 自身の CMake 既定値）。

| 設定 | Rust の参照ビルド | 共有 LLVM (Swift) | 判定 |
| --- | --- | --- | --- |
| ビルド種別 | Release (`llvm.optimize=true`) | `release` | 同一 |
| アサーション | OFF (`llvm.assertions=false`) | `-DLLVM_ENABLE_ASSERTIONS=OFF` | 同一 |
| 例外 (EH) | 未指定 → CMake 既定 OFF | `-DLLVM_ENABLE_EH=OFF` | 同一 |
| RTTI | 未指定 → CMake 既定 OFF | `-DLLVM_ENABLE_RTTI=ON` | **共有側が上位互換**（§4.2） |
| スレッド | 未指定 → 既定 ON | `-DLLVM_ENABLE_THREADS=ON` | 同一 |
| zlib（iOS ツリー） | `*-apple-{ios,tvos,watchos,visionos}` では OFF を明示 | `-DLLVM_ENABLE_ZLIB=OFF` | 同一 |
| zlib（macOS ツリー） | ホスト向けは ON | OFF（両ツリー同じ値しか渡せない） | **差**（§4.1） |
| zstd | `llvm.libzstd` 既定 **false** → `-DLLVM_ENABLE_ZSTD=OFF` | `-DLLVM_ENABLE_ZSTD=OFF` | 同一 |
| terminfo | 未指定 → 見つかれば ON | `-DLLVM_ENABLE_TERMINFO=ON` | 同一 |
| バックトレース | 未指定 → 既定 ON | `-DLLVM_ENABLE_BACKTRACES=ON` | 同一 |
| `llvm_unreachable` の最適化 | `-DLLVM_UNREACHABLE_OPTIMIZE=OFF` | 同じ | 同一 |
| プラグイン | apple モバイルでは OFF を明示 | 未指定 → CMake 既定（Darwin は `LLVM_ENABLE_PIC` に従い ON） | **共有側が上位互換**（§4.3） |
| LLVM 自体の LTO | `llvm.thin-lto` 既定 false | 未指定 | 同一 |
| **バックエンド** | `llvm.targets` 既定 **`all`** | `llvm-targets-to-build=all` | 同一（両者の既定集合を含む上位集合） |
| テスト | `llvm.tests=false` → OFF | `llvm-include-tests=0` | 同一 |
| libxml2 | OFF を明示 | 未指定（見つかれば ON） | 共有側が上位互換（rustc は使わない） |
| Z3 | OFF | 未指定 | 実質同一 |
| `LLVM_INSTALL_UTILS` | ON | 使わない（§1 の 15 個を自前で配置） | 同一（配置は §1） |

CMake のオプションは `Scripts/swift-ios-toolchain-presets.ini`
（`extra-cmake-options` と `llvm-targets-to-build`）にあります。
`extra-cmake-options` は **macOS 用と iOS 用の両ツリーに同じ値**が渡ります
（`utils/build-script` の cmake 呼び出しで、Swift 自身の `-D` より後ろに
`${EXTRA_CMAKE_OPTIONS[@]}` が並ぶ）。そのため片方だけ ON にする設定は
書けません。§4.1 の zlib が差として残っているのはこの理由です。

> 以前の版のこの文書は zstd を「差」と書いていましたが、それは誤りでした。
> `llvm.libzstd` の既定は `false`（`config.rs`: `llvm_libzstd.unwrap_or(false)`）
> で、rust も `LLVM_ENABLE_ZSTD=OFF` を渡します（`llvm.rs`: 885–889）。

## 3. Rust 側のビルド構成: 公式配布ビルドとの比較

公式バイナリの構成は rust-lang/rust の CI 定義
（`src/ci/github-actions/jobs.yml` の `--set rust.lto=thin --set
rust.codegen-units=1`、`src/ci/run.sh` の `--set rust.codegen-units-std=1`）が
正です。

| 設定 | 公式配布ビルド | 以前の rustios | 現在の rustios | 影響 |
| --- | --- | --- | --- | --- |
| `rust.lto` | `thin` | 既定 (`thin-local`) | **`thin`** | rustc 本体の最適化。以前は公式より遅い rustc だった |
| `rust.codegen-units` | `1` | `16` | **`1`** | 同上 |
| `rust.codegen-units-std` | `1` | 未設定 | **`1`** | std の最適化 |
| `build.optimized-compiler-builtins` | `true`（既定） | **`false`** | **`true`** | `memcpy`/`__divti3` などの組み込み実装。以前は純 Rust 版 |
| `rust.llvm-tools` | `true`（既定） | **`false`** | **`true`** | `lib/rustlib/<host>/bin` の有無 |
| `rust.codegen-tests` | `true`（既定） | **`false`** | FileCheck があれば `true` | `x.py test` の codegen テストのみ |
| `build.sanitizers` | 既定 `false`（dist ジョブが明示的に有効化） | `false` | `false` | §4 |
| `build.extended` | dist は `true` | `false` | `false` | 成果物に影響しない（必要なステップを明示指定している） |
| `build.submodules` | 自動 | `false` | `false` | `compiler-rt` を自前で置くため。§1 |

`lto=thin` と `codegen-units=1` は**ビルド時間**と引き換えです。3 コアの
macOS ランナーで stage1+stage2 が 35 分程度だったところから増えますが、
ジョブ上限は 6 時間なので吸収できます。成果物の性能を公式と揃えるための
コストとして受け入れています。

`RUST_LTO` / `RUST_CODEGEN_UNITS` で上書きできます（速くビルドしたいとき用）。

---

## 4. 残る差と、その影響の限定

「1% も落とさない」に対する答えは、**上位互換の差しか残っていない**ことです。
下の 4.1 だけが「共有ツリーのほうが少ない」差で、しかも成果物には現れません。

### 4.1 zlib（macOS ツリーのみ、成果物には影響しない）

- `--extra-cmake-options` は両ツリーに同じ値が渡るため、zlib は「両方 OFF」か
  「両方 ON」しか選べません（§2 の注記）。
- 共有ツリーは **OFF** を選びました。これは rust が `*-apple-ios` 向けに
  明示する値（`llvm.rs`: 「Zlib fails to link properly」）と同じで、
  **出荷される iOS ツリーは参照ビルドと完全に一致**します。
- 差が残るのは macOS ツリー（＝ビルド機で動く stage1 rustc がリンクする LLVM）
  だけです。rust のホスト向け LLVM は zlib ON なので、stage1 rustc は
  `SHF_COMPRESSED` なデバッグセクションを読める、という違いがあります。
- 成果物への影響: std は release・デバッグ情報なしで作るので圧縮セクションは
  存在せず、`-Zdebuginfo-compression` は nightly 専用（このビルドは
  `channel = "stable"`）。**端末で動く rustc の能力に差はありません。**
- 将来これが必要になったら、macOS ツリーだけ別の cmake オプションで
  ビルドする（`build-script` を 2 回呼ぶ）ことになり、この文書の範囲外です。

### 4.2 RTTI（共有側が上位互換）

Swift のビルドは `LLVM_ENABLE_RTTI=ON` を要求します（Swift 自身が使う）。
Rust の参照ビルドは OFF ですが、`rustc_llvm` の C++ ラッパーは RTTI を
一切使いません（`compiler/rustc_llvm/llvm-wrapper/` に `RTTI`/`rtti` の
出現なし、`build.rs` も `--has-rtti` を問い合わせない）。差は
`llvm-config --cxxflags` に `-fno-rtti` が付くかどうかだけで、生成コードには
影響しません。ON は「Rust 側が余分に得る」方向なので、1% の損失になりません。

### 4.3 プラグイン（共有側が上位互換）

rust は apple モバイル向けに `LLVM_ENABLE_PLUGINS=OFF` を明示します
（`-bundle` が CFLAGS に混ざるのを避けるため）。共有ツリーは未指定なので
CMake 既定（Darwin では `LLVM_ENABLE_PIC` に従い ON）です。
`rustc` は LLVM のパスプラグインを `dlopen` しないため、**観測できる差は
ありません**。このツリーで macOS/iOS 両方のビルドが通ることは既に実績があります
（`docs/llvm-sharing.md` の CI 履歴）。

### 4.4 sanitizer (`build.sanitizers = false`)

- bootstrap の既定値は `false` です（`config.rs`: `sanitizers:
  build_sanitizers.unwrap_or(false)`）。公式の dist ジョブが明示的に有効化して
  いるだけで、`x.py` の既定からの逸脱ではありません。
- 有効にすると `-Zsanitizer=…` 用のランタイムを std に同梱しますが、
  `-Z` は stable チャネルでは使えず、iOS の ASan ランタイムは Xcode が
  提供します。**観測できる差はありません**。

### 4.5 バックエンドを `all` にしたコストと CI の分割

- 実測（`docs/llvm-sharing.md` の CI 履歴）:
  - `AArch64` だけ: compiler-rt の builtins が失敗
    （`-arm-add-build-attributes` は ARM バックエンドにある）;
  - `AArch64;ARM;X86`: 約 4 時間で通るが、AMDGPU/NVPTX/RISCV/WebAssembly/…
    が無い。**rustc がそのターゲットのコードを生成できない**ので、参照ビルド
    に対する能力差になる;
  - `all`: 両ツリーで約 5 時間 30 分。パッケージングまで同じジョブでやると
    6 時間のジョブ上限に当たる（実測: 5 時間 55 分でパッケージ中に打ち切り）。
- 対処: `.github/workflows/build-rust-ios.yml` を 2 ジョブに分割しました。
  - `swift`: ビルドしてキャッシュ（`swift-built-*`）に保存するだけ;
  - `swift_package`: 同じキーでキャッシュを復元し、パッケージ・検証・
    アップロードを行う。
- キャッシュは `restore-keys` の前方一致でも復元されるため、**古いプリセットで
  ビルドしたツリーを掴まないように**、ツリー自身が
  `SwiftLLVM/llvm-project.txt` に `targets=`（と `targets_built=`）を記録し、
  復元直後にプリセットの値と比較します（違えばビルドし直す）。
- それでもビルドジョブが 6 時間を超えるようなら、次の選択肢は
  バックエンドを減らすことですが、そのときはこの文書とレポートに
  「どのバックエンドを落としたか」を必ず書きます（黙って減らさない）。

## 5. CI でどう確認しているか

`artifacts/REPORT.txt`（PR コメントに出る）に、次の行が追加されます。

```
swift LLVM (ios/bin): 15/15 rustc LLVM tools installed
swift LLVM (macosx/bin): 15/15 rustc LLVM tools installed
swift LLVM (macosx/bin): FileCheck present
swift LLVM: 15/15 rustc LLVM tools present and iOS/arm64
swift LLVM: 21 backends (AArch64;AMDGPU;ARM;AVR;BPF;...;XCore;Xtensa)
swift LLVM: backends match the preset (llvm-targets-to-build=all)
configure: llvm-tools = true (14 tools from the shared LLVM, macOS and iOS)
configure: optimized-compiler-builtins = true (compiler-rt <commit>)
configure: codegen-tests = true (FileCheck from the shared LLVM)
shared LLVM backends: 21 (...) = llvm-targets-to-build=all
compiler_builtins: compiler-rt C intrinsics built (<dir>/libcompiler-rt.a, N objects)
llvm-tools: 14/14 tools in lib/rustlib/aarch64-apple-ios/bin (rust-objcopy present)
RustToolchain: llvm-tools 60M (15 files in lib/rustlib/aarch64-apple-ios/bin)
```

- ツール（`llvm-tools`）が有効になるのは、**macOS と iOS の両ツリーに
  14 個すべてが揃っているときだけ**です。1 つでも欠ければ
  `llvm-tools = false` に落として理由をレポートに残します（6 時間かけた
  ビルドを、道具が 1 つ無いせいで落とさないため）。
- バックエンドは、プリセットの値（`all`）と `llvm-config --targets-built`
  の答えを突き合わせます。違えば
  `swift LLVM: **backends differ**` と、Rust 側では
  `shared LLVM backends: **N** ... - not full parity` が出ます。
  `AArch64` が無い場合だけは rustc が動かないので即エラーです。

## 6. この文書の範囲外

- Swift ツールチェーンの中身（stdlib の同梱範囲）は
  [llvm-sharing.md](llvm-sharing.md) §0 の成果物構成の話で、ここでは扱いません。
- `Rust.xcframework` の静的化（C API 付き）は
  [llvm-sharing.md](llvm-sharing.md) §6 の継続課題です。
- Swift 側のビルド時間そのものの短縮（ccache、分散ビルドなど）。
