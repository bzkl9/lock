# Applying or approving updates to `lock71.lua`

Follow these steps to ensure you pick up the full script and confirm the changes locally.

## 1) Confirm your workspace is clean
```sh
git status -sb
```
Make sure there are no unexpected modified files before pulling new changes.

## 2) Pull or fetch the latest commit
If you have a remote set up, grab the current branch updates:
```sh
git pull --ff-only
```

## 3) Verify you have the complete file
Some copy/paste paths truncate around 700–800 lines. After pulling, check the line count directly from disk:
```sh
wc -l lock71.lua
```
You should see roughly **1,500+ lines**. If you see ~735 lines, redownload the file instead of using a truncated paste.

## 4) Review the diff
Inspect what changed before approving or deploying:
```sh
git diff --stat
```
Optionally open the full diff:
```sh
git diff
```

## 5) Approve/apply
If everything looks good:
```sh
git commit --allow-empty -m "Approve lock71.lua updates"
```
(Use `--allow-empty` only if there are no file changes and you just want an audit trail.)

If you need to copy the script elsewhere, prefer downloading the file from version control or copying in smaller chunks to avoid truncation.
