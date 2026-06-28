import argparse
import calendar
import sys
import zipfile
from datetime import date, datetime
from pathlib import Path


APP_DIR = Path(__file__).resolve().parent
PYDEPS = APP_DIR / "pydeps"
if PYDEPS.exists():
    sys.path.insert(0, str(PYDEPS))


def parse_cdsapirc(path):
    config = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        config[key.strip()] = value.strip()
    if not config.get("url") or not config.get("key"):
        raise RuntimeError(".cdsapirc harus berisi baris 'url:' dan 'key:'")
    return config


def month_windows(start, end):
    cursor = date(start.year, start.month, 1)
    while cursor <= end:
        last_day = calendar.monthrange(cursor.year, cursor.month)[1]
        month_start = max(start, cursor)
        month_end = min(end, date(cursor.year, cursor.month, last_day))
        yield cursor.year, cursor.month, list(range(month_start.day, month_end.day + 1))
        if cursor.month == 12:
            cursor = date(cursor.year + 1, 1, 1)
        else:
            cursor = date(cursor.year, cursor.month + 1, 1)


def looks_like_netcdf(path):
    try:
        header = Path(path).read_bytes()[:8]
    except OSError:
        return False
    return header.startswith(b"CDF") or header.startswith(b"\x89HDF\r\n\x1a\n")


def main():
    parser = argparse.ArgumentParser(description="Download ERA5 single-levels data from CDS API.")
    parser.add_argument("--cdsapirc", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--start-date", required=True)
    parser.add_argument("--end-date", required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    try:
      import cdsapi
    except ImportError as exc:
      raise RuntimeError("Python package 'cdsapi' belum terinstall. Jalankan: pip install cdsapi") from exc

    config = parse_cdsapirc(args.cdsapirc)
    start = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    end = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    client = cdsapi.Client(url=config["url"], key=config["key"])
    times = [f"{hour:02d}:00" for hour in range(24)]

    for year, month, days in month_windows(start, end):
        target = out_dir / f"era5_cilegon_{year}_{month:02d}.nc"
        download_target = out_dir / f"era5_cilegon_{year}_{month:02d}.download"
        extracted_targets = list(out_dir.glob(f"era5_cilegon_{year}_{month:02d}*.nc"))
        if extracted_targets and not args.force and all(looks_like_netcdf(path) for path in extracted_targets):
            continue
        request = {
            "product_type": ["reanalysis"],
            "variable": [
                "2m_temperature",
                "2m_dewpoint_temperature",
                "total_precipitation",
            ],
            "year": [str(year)],
            "month": [f"{month:02d}"],
            "day": [f"{day:02d}" for day in days],
            "time": times,
            "data_format": "netcdf",
            "download_format": "unarchived",
            "area": [-5.80, 105.85, -7.30, 107.85],
        }
        if download_target.exists():
            download_target.unlink()
        for old_target in out_dir.glob(f"era5_cilegon_{year}_{month:02d}*.nc"):
            old_target.unlink()
        client.retrieve("reanalysis-era5-single-levels", request, str(download_target))
        if zipfile.is_zipfile(download_target):
            with zipfile.ZipFile(download_target) as archive:
                nc_members = [name for name in archive.namelist() if name.lower().endswith(".nc")]
                if not nc_members:
                    raise RuntimeError(f"CDS response ZIP tidak berisi file NetCDF: {download_target}")
                for i, member in enumerate(nc_members):
                    member_target = target if len(nc_members) == 1 else out_dir / f"era5_cilegon_{year}_{month:02d}_{i + 1:02d}.nc"
                    with archive.open(member) as src, member_target.open("wb") as dst:
                        dst.write(src.read())
            download_target.unlink()
        else:
            download_target.replace(target)


if __name__ == "__main__":
    main()
