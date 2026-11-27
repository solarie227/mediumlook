#!/bin/bash
# Swift のソースに埋め込んだ Metal シェーダーを取り出して、Metal コンパイラで確かめる
# （シェーダーは実行時にコンパイルするので、swift build では書き間違いが見つからないため）
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
perl -0777 -ne 'my $i = 0; while (/enum (\w+) \{\s*static let source = #"""\n(.*?)\n"""#/sg) { open(my $f, ">", "'"$OUT"'/$1.metal") or die; print $f $2; close $f; $i++ } die "シェーダーが見つかりません\n" unless $i' Sources/MediumLook/BokehShader.swift
for file in "$OUT"/*.metal; do
    echo "確認: $(basename "$file")"
    xcrun -sdk macosx metal -std=metal3.0 -c "$file" -o "${file%.metal}.air"
done
echo "シェーダーはすべてコンパイルできました"
