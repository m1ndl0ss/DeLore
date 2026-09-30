from pathlib import Path
from shutil import copyfile
from PIL import Image

root = Path(r"C:\Users\MatKa\DeLore\DeLore")
src_path = Path(
    r"C:\Users\MatKa\.cursor\projects\c-Users-MatKa-DeLore-DeLore\assets\c__Users_MatKa_AppData_Roaming_Cursor_User_workspaceStorage_29be79c420eb803fd196af01002c896a_images_image-d900f2bd-d109-45c6-9012-02f1675d0672.jpg"
)
brand_dir = root / "App/Resources/Brand"
brand_dir.mkdir(parents=True, exist_ok=True)
kept = brand_dir / "retract-mark.jpg"
if src_path.exists():
    copyfile(src_path, kept)
img = Image.open(kept if kept.exists() else src_path).convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)

ios_icon = root / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
ios_icon.parent.mkdir(parents=True, exist_ok=True)
img.save(ios_icon, "PNG")

brand = root / "App/Resources/Assets.xcassets/BrandMark.imageset"
brand.mkdir(parents=True, exist_ok=True)
img.resize((256, 256), Image.Resampling.LANCZOS).save(brand / "BrandMark.png", "PNG")
img.resize((512, 512), Image.Resampling.LANCZOS).save(brand / "BrandMark@2x.png", "PNG")
img.resize((768, 768), Image.Resampling.LANCZOS).save(brand / "BrandMark@3x.png", "PNG")

android_res = root / "Android/app/src/main/res"
for folder, size in [
    ("drawable-mdpi", 64),
    ("drawable-hdpi", 96),
    ("drawable-xhdpi", 128),
    ("drawable-xxhdpi", 192),
    ("drawable-xxxhdpi", 256),
]:
    d = android_res / folder
    d.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.Resampling.LANCZOS).save(d / "brand_mark.png", "PNG")

for folder, size in [
    ("drawable-mdpi", 108),
    ("drawable-hdpi", 162),
    ("drawable-xhdpi", 216),
    ("drawable-xxhdpi", 324),
    ("drawable-xxxhdpi", 432),
]:
    d = android_res / folder
    d.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.Resampling.LANCZOS).save(d / "ic_launcher_foreground.png", "PNG")

for folder, size in [
    ("mipmap-mdpi", 48),
    ("mipmap-hdpi", 72),
    ("mipmap-xhdpi", 96),
    ("mipmap-xxhdpi", 144),
    ("mipmap-xxxhdpi", 192),
]:
    d = android_res / folder
    d.mkdir(parents=True, exist_ok=True)
    sized = img.resize((size, size), Image.Resampling.LANCZOS)
    sized.save(d / "ic_launcher.png", "PNG")
    sized.save(d / "ic_launcher_round.png", "PNG")

print("icons written")
