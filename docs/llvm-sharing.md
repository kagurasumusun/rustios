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
- **どちらのコンパイラも機能を失わないこと**（LLVM の CMake 構成、llvm-tools、
  compiler-rt、`lto`/`codegen-units` の突き合わせ）: [llvm-parity.md](llvm-parity.md)

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

### 現状（2026-10-27）

| 要求 | 状態 |
| --- | --- |
| **両方のコンパイラが機能を失わない** | **CI で成功**: 20 バックエンド版（run 40402352677）で `llvm-tools = true` / `optimized-compiler-builtins = true` / `codegen-tests = true`。AArch64 のみの版（run 40803245579 / 40809695799）でも Swift 6.4 とその LLVM がビルド・パッケージ・検証まで通り、rustc 側の 3 つのフラグも同じ。詳細は [llvm-parity.md](llvm-parity.md) |
| **バックエンドは AArch64 のみ**（2026-10-27 の方針） | **CI で成功**（run 40803245579 冷間 3 h 21 m、run 40809695799 キャッシュ 3 m 49 s）: `swift LLVM: 1 backends (AArch64)` / `backends match the preset` / `shared LLVM backends: 1 (AArch64)`、ライブラリ 199 → 102、`SwiftLLVM` 240 → 160 M、`LLVM.xcframework` 53 → 41 M。`build-embedded-stdlib=0` がベアメタル ARM の builtins を止めています（run 40470888454 で原因確定）。`install_llvm` が両ツリーの `--targets-built` を preset と突き合わせ、違えば die します。**失うもの**: `aarch64-apple-ios` 以外へのクロスコンパイル（[llvm-parity.md](llvm-parity.md) §4.5） |
| **zlib もツリーごとに参照ビルドと同じ** | **CI で成功**: iOS ツリー OFF / macOS ツリー ON（レポート行 `SwiftLLVM: zlib ON in the macOS tree, OFF in the iOS tree`、run 40768756426 / 40809695799）。preset ではなく `seed_llvm_trees` が各ツリーの CMake キャッシュに入れ、`install_llvm` が `llvm-config.h` と `-lz` で検証（[llvm-parity.md](llvm-parity.md) §2.1） |
| **`Rust.xcframework` が C API をエクスポートする** | **CI で成功**（run 41124748670）: `libRustCompiler.a` に `rustios_run` / `rustios_version`、`Headers/rustios.h` を `#include` したテストアプリが `clang -target arm64-apple-ios16.0` で**リンク成功**（`"c_api": true`）。run 40803539605 で未定義だったアロケータのシムと generic を潰した結果。§6 |
| Swift コンパイラを iOS 向けにビルドする | **CI で成功**（Swift 6.4、`swift-frontend` は IOS/arm64、`SwiftToolchain` 544 MB。`swiftc`/`swift`/`swift-driver` は macOS のホストドライバ） |
| Swift が使う LLVM を iOS 設定でビルドする | **CI で成功**（`SwiftLLVM` 240 MB、`LLVM.xcframework` 53 MB。iOS 側 `lib/*.a` のメンバーを `vtool` で検査し `IOS/arm64` を確認） |
| Rust を Swift の LLVM でビルドする | **CI で成功**（20 バックエンド: run 40402352677、AArch64 のみ: run 41124748670 で `RustToolchain` 80 MB + `RustStd` 336 MB + `Rust.xcframework` 176 MB）。`verify` が「Swift の LLVM を使った」ことをビルド生成物から確認 |
| Rust 専用の LLVM を別にビルドしない | **実装済み**（`src/llvm-project` の LLVM は fetch しない、`llvm-config` を渡す）。`compiler-rt` だけは同じコミットから取る（[llvm-parity.md](llvm-parity.md)） |
| バージョン整合の証拠 | §1 / §2 |
| std をツールチェーンから分離 | **実装済み**（`RustStd`）。`RustToolchain` 側に std が漏れていないことを `package` が確認 |
| 未完了項目の明示 | §6 |

CI の履歴:

1. `--skip-build-swift` が `build-script` に拒否される → 1 回のビルドに統合。
2. `llvm-targets-to-build=AArch64` で compiler-rt の builtins（ベアメタル ARM）が失敗
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
9. **共有 LLVM の能力を rust に揃えた回**（run 40402352677、3 時間 36 分で全成功）。
   `llvm-targets-to-build=all`（20 バックエンド）、backtraces/terminfo/unreachable
   の設定を rust と同一にし、`build-toolchain-only=1` のせいで空だった
   `bin/` に rustc 用 15 ツールをビルド後に追加。Rust 側は
   `llvm-tools = true`（14/14 が sysroot に）、`optimized-compiler-builtins = true`
   （compiler-rt の C 実装 145 objects）、`codegen-tests = true`、
   `lto=thin`/`codegen-units=1` でビルド。当時は **C API 付き
   `Rust.xcframework` だけが未達**（`E0463`）で、これを次の回で解決しました（§6）。
10. **バックエンドを AArch64 だけにし、残りを全部閉じる回**（2026-10-27〜29）。
    * run 40470888454: Swift 側のビルドで失敗。原因は compiler-rt のベアメタル
      ARM builtins（下記）。
    * run 40768756426（`build-embedded-stdlib=0` の修正後）: **Swift 側の
      ビルド自体は成功**（4 時間 16 分、builtins の失敗は再発せず、zlib は
      macOS 1 / iOS 0）。ただし `install_llvm` に足したバックエンド検査が
      `llvm-iphoneos-arm64/bin/llvm-config` を呼んで落ちました。このツリーは
      `build-toolchain-only=1` → `LLVM_BUILD_TOOLS=NO` で **ツールを 1 つも
      作りません**（macOS ツリーだけは llvm-config を持ちます）。検査を
      `include/llvm/Config/Targets.def` から読む形に直して再実行中です。
    * この失敗で分かったこと: ビルド 4 時間はキャッシュに入らない
      （`swift-source/build` は 10 GB のキャッシュ上限に対して大きすぎる）ので、
      検査コードの不具合は毎回 4 時間の再ビルドになります。検査はローカルの
      ハーネス（`llvm-config` あり / `Targets.def` のみ / 広いツリー / 情報なし）で
      先に通しています。
    * `llvm-targets-to-build=AArch64`。run 40470888454 で、これを失敗させていたのは
      compiler-rt の builtins プロジェクトが Embedded Swift 用に作るベアメタル ARM
      （`macho_embedded_*`、32bit）だと確定。preset の `build-embedded-stdlib=0` で
      その 1 変数だけを止めた（osx / ios の builtins は従来通り）。
      `-DCOMPILER_RT_BUILD_BUILTINS=OFF` では止まらない理由は [llvm-parity.md](llvm-parity.md) §4.5。
    * zlib をツリーごとに設定（iOS OFF / macOS ON = rust の参照ビルドと同じ）。
      `seed_llvm_trees` が CMake キャッシュに入れ、`install_llvm` が検証する。
    * C API を `rustc_driver_impl` にコンパイル（`patches/0003`）し、
      静的アーカイブが `rustios_run` / `rustios_version` をエクスポートするように
      した。`build_xcframework` はシンボルを確認してから LLVM を同梱し、
      テストアプリを実際にリンクする（§6「C API の解決」）。
    * 失敗の再発防止として `install_llvm` が **両ツリーの `--targets-built` を
      preset と突き合わせ、違えば die** するようにした（以前は Rust 側で警告する
      だけ）。CI のキャッシュ復元も `targets_built=` を見て、古い preset で
      ビルドしたツリーを掴まないようにした。
    * `patches/*.patch` は先頭の `# rustios-patch-mode:`（`swift` / `all`）で
      適用条件を宣言し、`apply_rust_patches` はその行が無ければ die する。
      `0002`（iOS の libc++）と `0003`（C API）は LLVM に依存しないので `all`、
      `0001`（PGOOptions）だけが `swift`。
    * 失うもの: `aarch64-apple-ios` 以外へのクロスコンパイル（§4.5）。
    * run 40803245579: **AArch64 のみで Swift + LLVM のビルドとパッケージが成功**
      （3 h 21 m、`1 backends (AArch64)`、`SwiftLLVM 160 M` / `LLVM.xcframework 41 M`、
      zlib は macOS ON / iOS OFF）。同じ内容がキャッシュから 3 m 49 s で復元される
      ことも run 40809695799 で確認。
    * run 40803539605（`build-rust-from-artifact`、20 バックエンドの LLVM を再利用）:
      **C API が `libRustCompiler.a` に入った**（3664 objects / 329 rlibs、
      `nm -g` に `_rustios_run` / `_rustios_version`）。ただしアプリのリンクテストで
      未定義記号が出て失敗。原因は 2 つで、どちらも「rustc の最終リンクでしか
      作られないもの」: アロケータのシム（`__rust_alloc` 系）と、C API モジュールの
      `OnceLock<CString>` の generic（§6）。前者は `add_allocator_shims` で
      アーカイブに弱い定義として同梱し、後者は `patches/0003` を固定バッファに
      書き換えて消した。
    * run 41124748670（AArch64 のみの LLVM、Swift はキャッシュから 3 m 49 s）:
      **全ステップ成功**。`static archive = 2730 iOS objects from 329 rlibs (0 dropped),
      C API exported`、`libRustCompiler.a = rustc + LLVM, 943M`、そして
      **`link test passed`**（`clang -target arm64-apple-ios16.0`）。テストアプリは
      `Headers/rustios.h` を `#include` して `rustios_version()` を呼ぶので、
      C API とアロケータのシムが実際に解決されることの証明になります。
      この run のレポートには `allocator shims **not** effective` という**誤った**
      行が残りました（`nm -u` はアーカイブの**全メンバー**の未定義記号を並べるので、
      シムが定義しても他のメンバーの参照が残って見える）。判定を「アーカイブ内に
      定義があるか」に直し、その偽陽性を再現するケースをローカルのハーネスに
      追加しました。
    * run 40809695799: Rust ジョブが `fetch` で失敗。`rust-src` キャッシュは
      **パッチ適用後のツリー**なので、`patches/0003` を書き換えるとキャッシュ上の
      旧版と衝突して「適用も逆適用もできない」状態になり、`die` していました。
      `apply_rust_patches` はその場合にパッチが触るファイルだけを HEAD に戻して
      再試行するようにし（7.6 GB のキャッシュを捨てない）、`fetch` も `build.log` に
      tee するようにしました（それまではレポートに「build.log is empty」とだけ出た）。

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
| `[rust] llvm-tools` | `true`（共有 LLVM に 14 個揃っている場合） | bootstrap が `SwiftLLVM/{ios,macosx}/bin` から `lib/rustlib/<host>/bin` へ導入する。揃っていない場合は `false` にして理由をレポート |
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
**失敗**させます。無理に押し通さない）。どれをどのモードで当てるかは、各パッチの
先頭にある 1 行が決めます:

```
# rustios-patch-mode: swift   # Swift の LLVM をリンクする時だけ（= 上の API 差）
# rustios-patch-mode: all     # どのモードでも（= LLVM に依存しない rustc 側の修正）
```

この行が無いパッチは**エラー**です（推測しない）。`intree` モードでも
`0002`（`aarch64-apple-ios` で `libc++` をリンクする）と `0003`（C API）は当たり、
`0001` だけが当たりません。理由は各パッチのヘッダにも書いてあります。

## 3. Swift 側の LLVM

`Scripts/swift-ios-toolchain-presets.ini` は emexlab/LLVM-On-iOS の
`nyxian_iphoneos_arm64_crosscompiler` を元にしたプリセットで、LLVM を 2 回
ビルドします（同じソース、同じターゲット構成）。

`llvm-targets-to-build=AArch64` です: Swift も rustc も arm64 上で動き、
rustc のターゲットは `aarch64-apple-ios` だけなので、他のバックエンドは
ビルド時間とサイズにしかなりません（[llvm-parity.md](llvm-parity.md) §4.5）。

その代わり、この rustc は **`aarch64-apple-ios` 以外のターゲット向けに
コードを生成できません**。参照ビルド（`llvm.targets=all`）に対する唯一の
実質的な能力差で、利用者の判断（2026-10-27）で受け入れています。

これを通すために **`build-embedded-stdlib=0`** を指定しています（run
40470888454 で原因を確定）。build-script は Embedded Swift 用に
`-DBUILTINS_<host-triple>_COMPILER_RT_FORCE_BUILD_BAREMETAL_MACHO_BUILTINS_ARCHS=…`
を渡し、compiler-rt の builtins プロジェクトが 32bit ARM の `macho_embedded_*`
（armv6m … armv8.1m.main）も作ります。AArch64 だけのコンパイラには ARM
バックエンドのオプション `-arm-add-build-attributes` が無いので、そこで失敗して
いました。`build-embedded-stdlib=0` はこの 1 変数だけを止め、clang とリンカが
実際に使う osx / ios の builtins は SDK から導出される別経路で作られ続けます
（`llvm-install-components` の `builtins` はそのまま）。

`-DCOMPILER_RT_BUILD_BUILTINS:BOOL=OFF` はこれとは別物で、止められません:
`llvm/runtimes/CMakeLists.txt` は `builtins-<host-triple>` という別プロジェクトを
立てて `compiler-rt/lib/builtins` を直接 configure するため、この変数を読みません
（sanitizer ランタイム側の builtins を止めるだけです）。詳細は
[llvm-parity.md](llvm-parity.md) §4.5。

zlib はツリーごとに値が違います（iOS OFF / macOS ON、どちらも rust の参照
ビルドと同じ）。`--extra-cmake-options` は両ツリー共通なので、preset ではなく
各ツリーの CMake キャッシュに入れています（[llvm-parity.md](llvm-parity.md) §2.1）。

`build-toolchain-only=1`（LLVM-On-iOS 由来）のため、`build-script` が作る
`bin/` にはツールが入りません。rustc が必要とする 15 個は、ビルド後に
既存のツリーへ `ninja` で追加リンクしています
（[llvm-parity.md](llvm-parity.md) §1.1）。

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
| `Scripts/build-rust-toolchain.sh` | `RUST_LLVM_MODE=swift` を追加。`bootstrap.toml` に `[target.*] llvm-config` と `llvm-has-rust-patches=false` を書き、`src/llvm-project` の LLVM は fetch せず、`verify` で LLVM の出所を証明する。`compiler-rt` は共有 LLVM と同じコミットから取り、`llvm-tools` は共有 LLVM に揃っている時だけ有効化する。既定 `RUST_VERSION=1.94.0` |
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
| Swift 6.4 の iOS ビルド（LLVM 2 種 + swift-frontend） | **CI で成功**（冷間 3 h 21 m / `AArch64` のみ、キャッシュ復元時 3 m 49 s。`swift-frontend` は iOS/arm64） |
| `swiftc`（ドライバ）の iOS 性 | **未確認／おそらくホスト用**: 直近の実行で macOS バイナリと判定（レポート `swiftc: MACOS (host binary; not counted as an iOS artifact)`）。`swift-frontend` が iOS なのでコンパイラとしては成立するが、ドライバをデバイスで使うには追加対応が要る |
| Swift ツールチェーンに混ざるホスト（macOS）バイナリ | **既知**: LLVM-On-iOS も `lib/swift/host/compiler/*.dylib` を同梱。`verify` は内訳をレポートし、iOS と偽らない |
| 静的ライブラリの iOS 性 | **CI で確認済み**: シンボルテーブル（`__.SYMDEF`）を除いたメンバー（`.o`）を `vtool` で `platform IOS` と照合し、非 iOS のオブジェクトはアーカイブから除外（`filter_non_ios_objects`）。run 41124748670 は `2730 iOS objects from 329 rlibs (0 build-machine objects dropped)` |
| Rust 1.94.0 が LLVM 21.1.6 でリンク・動作すること | **リンクは CI で成功**（rustc 本体・`llvm-tools`・`compiler_builtins` の C 実装まで、run 40402352677 / 41124748670）。**iOS 実機/シミュレータ上での実行は未検証**（この CI はビルドとリンクまでで、実行はできない） |
| rust-lang/llvm-project 固有パッチの全列挙 | **未完了**。`rustc/21.1-2025-08-01` は upstream `release/21.x` のマージが主で、bootstrap 側の分岐は `LLVM_RUSTLLVM` の定義だけ。ただし「1 つも無い」ことまでは確認できていない |
| 21.1.6 と 21.1.8 の差 | **patch のみ**（`release/21.x`）。実際に rustc を 21.1.6 の C++ API で**ビルドできた**ので（run 40402352677 / 41124748670）、必要だった API 差分は `0001`（`PGOOptions` の vfs 引数）1 件だけだった |
| `LLVM_ENABLE_RTTI=ON` と rustc_llvm の組み合わせ | **CI で確認済み**: プリセット側で ON、shim の `--has-rtti` も `YES` で、`rustc_llvm` のビルドスクリプトがそのまま通り、`libRustCompiler.a` が LLVM とリンクして動くテストアプリまで到達（run 41124748670） |
| rust-lang 版 LLVM との API 差 | **1 件検出・パッチ適用**（`PGOOptions` の vfs 引数 = `0001`。`swift` モード専用）。`stdc++`→`libc++` は LLVM の差ではなく iOS 向けクロスビルドの問題なので `0002`（全モード）に分けた。他にも同種の差があれば実ビルドで判明する |
| 静的 `Rust.xcframework`（`libRustCompiler.a`）+ C API | **CI で成功**（run 41124748670: `2730 iOS objects from 329 rlibs (0 dropped)`、`_rustios_run` / `_rustios_version` をエクスポート、`943M` with LLVM、`Headers/rustios.h` を include したテストアプリが `clang -target arm64-apple-ios16.0` でリンク成功、`"c_api": true`）。方式は下の「C API の解決」節。**アプリからの実行は未検証**（リンクまで） |
| `preflight`（ビルド前の数十秒チェック） | **実アーカイブで確認済み**（run 41124748670: `shared LLVM preflight: 21.0.0, 102 libraries, iOS slice confirmed (3 sampled)`）。エラー経路はスタブで確認済み |
| ビルド時間 | Swift は **3 h 21 m**（`AArch64` のみ・冷間、run 40803245579）、キャッシュ復元なら 3 m 49 s + 梱包 18 m。`all`（20 バックエンド）は 4 h 16 m。CI はビルド/パッケージを 2 ジョブに分割。Rust は stage1 + stage2 で約 1 h（run 41124748670: 21:13 → 22:10 UTC、xcframework のリンクテスト込み） |

静的ドライバの試行錯誤（すべて CI で実測）:

| 探索範囲 | 結果 |
| --- | --- |
| 明示 6 ディレクトリ（sysroot + `stage2-rustc/<host>`） | `E0463 can't find crate for derive_where` |
| `build/` 配下の全 `deps`（28 個） | `E0514 derive_where は rustc 1.93 でコンパイル済み`（stage0 版を掴んだ） |
| stage2 のみ（10 個） | `E0463` |
| stage2 のみ・**ホスト優先**（proc-macro はホスト用なので darwin を先に） | `E0463`（両順序を 1 回の実行で試す実装） |

stage2 のツリーには `libderive_where-720e60ae…dylib`（iOS 側）と
`libderive_where-d4b8fe3f…dylib`（darwin 側）、`librustc_driver_impl-8212aa2c….rlib`
が実在することをレポートで確認済み。それでも解決しなかった理由の見立て:

- `build/<host>/stage2/lib/rustlib/<host>/lib` の `librustc_driver_impl-8212aa2c…rlib`
  は **stage 1 の sysroot からコピーされたもの**で、stage 0（rustc 1.93）がビルドした
  `derive_where` を要求する。
- crate hash は cargo の unit から決まるので、コピー元の stage が違っても**ファイル名は
  同じ**になる。中身が違う同じ名前のファイルが並ぶため、探索範囲を広げても
  「正しい stage のコピー」を選べない。
- `extern crate rustc_driver_impl` は `rustc_private` の解決なので、`--extern` を
  与えない限り sysroot のコピーが `-L` より優先される。要求された hash の
  `derive_where` が stage2 側に無ければ `E0463`、stage0 側に見えれば `E0514`。

対処と結果（run 40258441852）:

1. `--extern rustc_driver_impl=<stage2-rustc/<host>/release/deps の rlib>` で stage 1 が
   ビルドしたドライバを明示し、`-L` は cargo の stage2 ディレクトリを先に置く
2. 同じ `-L` で `--extern` なし（sysroot 優先の確認）
3. sysroot 優先（従来の順序）
4. stage2 の `deps` 優先

の 4 通りを実装した。ただし最初の実行（40258441852）では**どれも
`error: unknown unstable option: `verbose`` で即座に落ちた**。`-Z verbose` は
rustc 1.94 のオプションではない（診断は `-Z verbose-internals`）。

修正後（`-Z verbose-internals`、run 40269093072 と 40402352677）は
**4 通りすべてが実際に走り、4 通りすべて `E0463`** だった:

```
attempt 0: --extern for the cargo-built driver, cargo directories first
attempt 1: cargo directories first
attempt 2: the sysroot first
attempt 3: stage-2 compiler directories first
  -> error[E0463]: can't find crate for `derive_where` which `rustc_driver_impl`
     depends on
```

候補として見えているのは `librustc_driver_impl-8212aa2c….rlib`（stage2 の
iOS 用）と `libderive_where-*.dylib`（macOS 用、stage1/stage2 の 3 種類）だけで、
**要求された hash の `derive_where` がどこにも無い**。`derive_where` は
proc-macro crate なので `.dylib` しか作られず、iOS 向け `rustc_driver_impl` の
メタデータが要求する版と一致しない。探索範囲を広げても解決しないため、
この経路は**諦めた**（下の「C API の解決」）。`build_xcframework` は
`patches/0003` が当たっていないツリーのためにだけ、この 4 通りを
フォールバックとして残しています。

一方、**フォールバックは機能した**（run 40269093072 でも同じ）: 4 通りが失敗したあと、rlib の中の
オブジェクトを `libtool -static` で 1 本の `libRustCompiler.a` にまとめ、
`Rust.xcframework` を**静的スライス**として出せた（`"library": "static"`,
`"c_api": false`、展開 685 MB → xz 96 MB、`ar -t` に `rustc_driver_impl` の
オブジェクトを含むことを確認。4831 objects / 329 rlibs）。オブジェクトは
crate メタデータを必要としないので、C シムが失敗しても「静的ライブラリ」
という要求は満たせます。

### C API の解決（`patches/0003-rustc-1.94.0-rustios-c-api.patch`）

上の 4 通りがすべて `E0463` だったのは、**静的アーカイブに crate メタデータが
無い**ことの帰結です。シムの crate は `extern crate rustc_driver_impl` を
解決しないとコンパイルできず、そのメタデータ（`.rmeta`）は rlib の中に
あっても、そこから読み込む `derive_where` の proc-macro dylib がビルド機の
cargo ディレクトリにしか存在しません。探索範囲をどう並べても、
「iOS 向け rustc_driver_impl が要求する hash の dylib」は作られていないのです。

そこで**要求の側を変えました**。C のエントリポイント（`rustios_version` /
`rustios_run`）を `rustc_driver_impl` 自身のモジュールとして追加し、bootstrap に
本体と同じメタデータでコンパイルさせます。オブジェクトは最初から
`libRustCompiler.a` の中に入るので、アプリのリンク時にも実行時にも
メタデータ解決は不要です。

* パッチは `compiler/rustc_driver_impl/src/lib.rs` に 1 行
  （`mod rustios_c_api;`）と、同じディレクトリへのモジュール 1 個を足すだけ。
  モジュールはパッチの中にあります（crate 内のモジュールである必要があり、
  リポジトリへの `#[path]` 参照は rustc のソースをこのリポジトリの配置に
  依存させてしまうため）。
* `build_xcframework` は rlib をまとめた `libRustCompiler.a` を作り、
  `nm -g` に `_rustios_run` / `_rustios_version` があることを確認して
  `"c_api": true` とします。ヘッダ（`Scripts/rustios-driver/include/rustios.h`）を
  `Headers/` に入れ、最後に `clang -target arm64-apple-ios…` で
  テストアプリを実際にリンクします。
* スタンドアロンのシム（`Scripts/rustios-driver/rustios_driver.rs`）は、
  パッチが当たっていないツリー用のフォールバックとして残しています。

#### 静的アーカイブが自分で持たなければならないもの

rlib を 1 本にまとめただけでは、**アプリからリンクできる**ライブラリには
なりません。rustc は「最終成果物」をリンクするときにしか作らないものが
2 種類あり、どちらも rlib の中には存在しません。

1. **アロケータのシム**（`__rust_alloc` / `__rust_dealloc` / `__rust_realloc` /
   `__rust_alloc_zeroed` / `__rust_no_alloc_shim_is_unstable_v2`）。
   `___rustc` という擬似 crate（記号名の `Cs5QKde7ScR4H` がそれ）の記号で、
   rustc が bin / cdylib をリンクするときに生成します。`std`・`alloc`・
   `gimli`・`rustc_driver_impl` のオブジェクトはこれらを**参照する**ので、
   Swift/C アプリが `libRustCompiler.a` をリンクすると
   `ld: symbol(s) not found ... ___rust_alloc` で止まります
   （run 40803539605 で実際に発生）。
2. **crate 内のジェネリックのインスタンス**（`__RINv…` / `__RNC…` / vtable）。
   同じ run で未定義だったのは、C API モジュールが `OnceLock<CString>` と
   `CString::new` を使っていたことに由来する 3 記号でした。

`build-rust-toolchain.sh` の `add_allocator_shims` は 1 を解決します。
アーカイブの未定義記号を `nm -g -u` から読み（記号名はビルドごとに変わり
うるのでハードコードしない）、malloc 系（`malloc` / `free` / `realloc`、
16 バイト超のアラインメントは `posix_memalign`）への**弱い定義**を
アーカイブに足します。std の `System` アロケータが Apple プラットフォームで
使うものと同じ系統で、弱いので「アプリ側が本物のシムを持っている」場合は
そちらが優先されます。2 はパッチ 0003 の側で、`version_cstr()` を
アトミックな固定バッファに変えて**アロケートもクロージャも使わない**形に
しました（`rustios_run` は rustc 本体を呼ぶのでアロケートしますが、それは
アロケータのシムがあれば足ります）。

`add_allocator_shims` と `bundle_llvm` は `finalize_static_archive` から
この順で呼ばれ、リンクテスト（`clang -target arm64-apple-ios…`）は
「アプリに落としたときに本当にリンクできるか」を確認します。

#### パッチの適用先がキャッシュされていること（run 40809695799 の失敗）

`rust-src-<CACHE_VERSION>-<ver>` キャッシュは、**パッチを当てたあとのツリー**を
保存します。そのため `patches/0003` を書き換えると、キャッシュされたツリーには
旧版が当たったままになり、新版は「適用できる」でも「逆適用できる（＝適用済み）」
でもなくなって `apply_rust_patches` が die しました（`fetch` は `build.log` に
出力していなかったので、レポートには「build.log is empty」とだけ出ました。
現在は `fetch` も `build.log` に tee します）。7.6 GB のキャッシュを捨てずに
済むよう、`apply_rust_patches` はその場合に**パッチが触るファイルだけを HEAD に
戻して**（`git checkout`、パッチが新規作成するファイルは削除）再試行し、
成功したら `rustc patches re-applied on a reset tree …` をレポートに残します。
本当に rustc 側が変わって適用できない場合は、従来通り die します。

既知の割り切り:

- **macOS 用 LLVM も Swift のビルド成果物から取ります。** 別の LLVM を作らないためで、
  rust-lang 版との混在はありません。
- `llvm-tools`（`llvm-ar` 等）は Swift のビルド成果物（iOS バイナリ）を
  `SwiftLLVM/ios/bin` に置き、bootstrap の `Sysroot` ステップに
  `lib/rustlib/aarch64-apple-ios/bin` へ入れさせます（`llvm-parity.md` §1）。
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
