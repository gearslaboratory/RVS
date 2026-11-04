"""
make_raster.py - turn an RVS output database into GeoTIFF rasters.

Each RVS plot has a latitude/longitude and one value per year. This script
places those values on a regular grid (30 m by default, California Albers
EPSG:3310) and writes one GeoTIFF per year, plus an optional PNG map with a legend
and latitude/longitude labels.

Run it with the GDAL Docker image (no Python install needed). From the folder
that holds your out/ and tools/ folders:

    docker run --rm -v "${PWD}:/data" -w /data ghcr.io/osgeo/gdal:ubuntu-small-3.9.3 python3 tools/make_raster.py out/foothills_baseline.db --variable total_carbon --year 9 --png

Use --list to see which variables and years are in a database.
"""

import argparse
import os
import sqlite3
import sys

import numpy as np
from osgeo import gdal, ogr, osr
from PIL import Image, ImageDraw, ImageFont

gdal.UseExceptions()

NODATA = -9999.0
MAP_PX = 600  # PNG maps are enlarged to about this many pixels on the long side

# Units shown on the PNG legend
UNITS = {
    "total_biomass": "lbs/acre", "shrub_biomass": "lbs/acre", "herb_biomass": "lbs/acre",
    "total_carbon": "C lbs/acre", "disturbance_amount": "lbs/acre",
    "tot_shrub_cov": "%", "herb_cover": "%", "avg_shrub_ht": "cm", "herb_height": "cm",
    "herb_fuel": "lbs/acre", "shrub_1hr_foliage": "lbs/acre", "shrub_1hr_woodbark": "lbs/acre",
    "fuel_1hr": "lbs/acre", "fuel_10hr": "lbs/acre", "fuel_100hr": "lbs/acre",
    "fuel_1000hr": "lbs/acre", "total_fuels": "lbs/acre",
}

# Viridis-like color stops (fraction of range, R, G, B) for PNG maps
RAMP = [
    (0.00, 68, 1, 84),
    (0.25, 59, 82, 139),
    (0.50, 33, 145, 140),
    (0.75, 94, 201, 98),
    (1.00, 253, 231, 37),
]
# Diverging stops for --compare (loss = red, no change = white, gain = blue)
RAMP_DIFF = [
    (0.00, 178, 24, 43),
    (0.50, 247, 247, 247),
    (1.00, 33, 102, 172),
]


def parse_args():
    p = argparse.ArgumentParser(
        description="Make GeoTIFF rasters from an RVS output database.")
    p.add_argument("databases", nargs="+",
                   help="RVS output database(s). Several databases (tiles) are merged into one raster.")
    p.add_argument("--variable", default="total_biomass",
                   help="Column to map, e.g. total_biomass, total_carbon, shrub_biomass, "
                        "herb_biomass, tot_shrub_cov (default: total_biomass)")
    p.add_argument("--year", default="last",
                   help="Year to map: a number (0 = first year), a list like 0,5,9, 'last' (default) or 'all'")
    p.add_argument("--table", default="Biomass_Output",
                   help="Output table to read (default: Biomass_Output; Fuels_Output also works)")
    p.add_argument("--compare", metavar="BASE_DB",
                   help="Map the difference: (this run) minus (BASE_DB), matched by plot location")
    p.add_argument("--cell-size", type=float, default=30.0,
                   help="Raster cell size in meters (default: 30)")
    p.add_argument("--epsg", type=int, default=3310,
                   help="Output projection EPSG code (default: 3310, California Albers)")
    p.add_argument("--out-dir", default="rasters",
                   help="Folder for the output files (default: rasters)")
    p.add_argument("--name",
                   help="Start of the output file names (default: the database name)")
    p.add_argument("--png", action="store_true",
                   help="Also write a PNG map (with legend and lat/long labels) for each raster")
    p.add_argument("--min", type=float, dest="vmin",
                   help="Lowest value on the PNG color scale (use the same --min/--max to compare maps)")
    p.add_argument("--max", type=float, dest="vmax",
                   help="Highest value on the PNG color scale")
    p.add_argument("--list", action="store_true",
                   help="Show the variables and years in the database, then stop")
    return p.parse_args()


def numeric_columns(conn, table):
    rows = conn.execute(f'PRAGMA table_info("{table}")').fetchall()
    if not rows:
        sys.exit(f"Table '{table}' was not found. Is this an RVS output database?")
    return [r[1] for r in rows
            if r[2].upper() in ("REAL", "FLOAT", "INTEGER", "INT", "DOUBLE")
            and r[1] not in ("latitude", "longitude", "year", "PLOT_ID", "BPS_CODE")]


def open_db(path, table, variable):
    if not os.path.exists(path):
        sys.exit(f"Can't find database: {path}")
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    cols = numeric_columns(conn, table)
    if variable not in cols:
        sys.exit(f"'{variable}' is not a numeric column in {table}.\nChoose one of: {', '.join(cols)}")
    return conn


def list_contents(path, table):
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    cols = numeric_columns(conn, table)
    n_plots, y0, y1 = conn.execute(
        f'SELECT count(DISTINCT PLOT_ID), min(year), max(year) FROM "{table}"').fetchone()
    print(f"\n{path}  ({table})")
    print(f"  plots: {n_plots}")
    print(f"  years: {y0} to {y1}")
    print("  variables:")
    for c in cols:
        print(f"    {c}")
    conn.close()


def years_in(conn, table):
    return [r[0] for r in conn.execute(f'SELECT DISTINCT year FROM "{table}" ORDER BY year')]


def pick_years(arg, available):
    if not available:
        sys.exit("The database has no output rows. Did the RVS run finish? (Years must be 1 or more.)")
    if arg == "last":
        return [available[-1]]
    if arg == "all":
        return available
    try:
        wanted = [int(y) for y in arg.split(",")]
    except ValueError:
        sys.exit(f"--year must be a number, a list like 0,5,9, 'last' or 'all' (got '{arg}')")
    missing = [y for y in wanted if y not in available]
    if missing:
        sys.exit(f"Year(s) {missing} not in the database. Available: {available[0]} to {available[-1]}")
    return wanted


def read_values(conns, table, variable, year):
    """Return {(lat, lon): value} for one year across all databases."""
    values = {}
    for conn in conns:
        q = f'SELECT latitude, longitude, "{variable}" FROM "{table}" WHERE year = ?'
        for lat, lon, v in conn.execute(q, (year,)):
            if lat is None or lon is None or v is None:
                continue
            values[(round(lat, 7), round(lon, 7))] = float(v)
    return values


def project_points(values, epsg):
    src = osr.SpatialReference()
    src.ImportFromEPSG(4326)
    src.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    dst = osr.SpatialReference()
    dst.ImportFromEPSG(epsg)
    dst.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    ct = osr.CoordinateTransformation(src, dst)
    keys = list(values)
    xy = np.array(ct.TransformPoints([(lon, lat) for lat, lon in keys]))[:, :2]
    z = np.array([values[k] for k in keys])
    return xy, z, dst


def write_geotiff(xy, z, srs, cell, path):
    # Snap the grid to whole cells so rasters from different runs line up
    half = cell / 2
    xmin = np.floor((xy[:, 0].min() - half) / cell) * cell
    xmax = np.ceil((xy[:, 0].max() + half) / cell) * cell
    ymin = np.floor((xy[:, 1].min() - half) / cell) * cell
    ymax = np.ceil((xy[:, 1].max() + half) / cell) * cell
    width = int(round((xmax - xmin) / cell))
    height = int(round((ymax - ymin) / cell))

    # Points go into a temporary vector layer, then gdal.Grid assigns each cell
    # the value of the nearest plot within 0.75 cells (cells with no plot stay empty)
    # GDAL 3.11 renamed the in-memory vector driver from "Memory" to "MEM"
    vec_driver = "MEM" if int(gdal.VersionInfo()) >= 3110000 else "Memory"
    mem = gdal.GetDriverByName(vec_driver).Create("pts", 0, 0, 0, gdal.GDT_Unknown)
    lyr = mem.CreateLayer("pts", srs, ogr.wkbPoint)
    lyr.CreateField(ogr.FieldDefn("value", ogr.OFTReal))
    for (x, y), v in zip(xy, z):
        f = ogr.Feature(lyr.GetLayerDefn())
        f.SetField("value", v)
        f.SetGeometry(ogr.CreateGeometryFromWkt(f"POINT ({x} {y})"))
        lyr.CreateFeature(f)

    radius = cell * 0.75
    gdal.Grid(path, mem, format="GTiff", zfield="value",
              outputBounds=[xmin, ymax, xmax, ymin], width=width, height=height,
              outputType=gdal.GDT_Float32,
              algorithm=f"nearest:radius1={radius}:radius2={radius}:nodata={NODATA}",
              creationOptions=["COMPRESS=DEFLATE"])
    ds = gdal.Open(path, gdal.GA_Update)
    ds.SetProjection(srs.ExportToWkt())
    ds.GetRasterBand(1).SetNoDataValue(NODATA)
    ds = None
    return width, height


def colorize(z, vmin, vmax, ramp):
    t = np.clip((z - vmin) / (vmax - vmin), 0, 1)
    stops = [s[0] for s in ramp]
    rgb = [np.interp(t, stops, [s[i] for s in ramp]) for i in (1, 2, 3)]
    return np.stack(rgb, axis=-1).astype(np.uint8)


def nice_ticks(lo, hi, target=5):
    """Round-numbered tick values between lo and hi, and the step between them."""
    span = hi - lo
    if span <= 0:
        return [lo], 1
    mag = 10 ** np.floor(np.log10(span / target))
    step = min((m * mag for m in (1, 2, 2.5, 5, 10)), key=lambda s: abs(span / s - target))
    first = np.ceil(lo / step - 1e-9) * step
    ticks = np.arange(first, hi + step * 1e-6, step)
    return [round(float(v), 10) + 0.0 for v in ticks], step  # + 0.0 turns -0.0 into 0.0


def decimals_for(step):
    return max(0, int(-np.floor(np.log10(step)))) if step < 1 else 0


def write_png(tif, png, vmin, vmax, ramp, title, units):
    """Save a PNG map with a color legend and latitude/longitude along the edges."""
    if vmax <= vmin:
        vmax = vmin + 1
    ds = gdal.Open(tif)
    z = ds.GetRasterBand(1).ReadAsArray().astype(float)
    x0, dx, _, y0, _, dy = ds.GetGeoTransform()
    srs = osr.SpatialReference(wkt=ds.GetProjection())
    ds = None
    rows, cols = z.shape

    # Color the cells (empty cells stay white) and enlarge small rasters
    rgb = colorize(z, vmin, vmax, ramp)
    rgb[z == NODATA] = 255
    scale = max(1, int(np.ceil(MAP_PX / max(rows, cols))))
    map_img = Image.fromarray(rgb, "RGB").resize((cols * scale, rows * scale), Image.NEAREST)
    mw, mh = map_img.size

    font = ImageFont.load_default(size=15)
    small = ImageFont.load_default(size=12)
    left, top, right, bottom = 85, 45, 140, 40
    canvas = Image.new("RGB", (left + mw + right, top + mh + bottom), "white")
    canvas.paste(map_img, (left, top))
    d = ImageDraw.Draw(canvas)
    d.rectangle([left - 1, top - 1, left + mw, top + mh], outline="black")
    d.text((left, top - 14), title, fill="black", font=font, anchor="ls")

    # Latitude ticks on the left edge, longitude ticks on the bottom edge
    wgs = osr.SpatialReference()
    wgs.ImportFromEPSG(4326)
    for s in (wgs, srs):
        s.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    to_ll = osr.CoordinateTransformation(srs, wgs)
    from_ll = osr.CoordinateTransformation(wgs, srs)
    x1, y1 = x0 + cols * dx, y0 + rows * dy
    lon_left, lat_bottom = to_ll.TransformPoint(x0, y1)[:2]
    lon_right = to_ll.TransformPoint(x1, y1)[0]
    lat_top = to_ll.TransformPoint(x0, y0)[1]

    lons, step = nice_ticks(min(lon_left, lon_right), max(lon_left, lon_right), 3)
    for lon in lons:
        px = left + (from_ll.TransformPoint(lon, lat_bottom)[0] - x0) / dx * scale
        if left <= px <= left + mw:
            d.line([px, top + mh, px, top + mh + 5], fill="black")
            label = f"{abs(lon):.{decimals_for(step)}f}°{'W' if lon < 0 else 'E'}"
            d.text((px, top + mh + 8), label, fill="black", font=small, anchor="mt")

    lats, step = nice_ticks(min(lat_bottom, lat_top), max(lat_bottom, lat_top), 4)
    for lat in lats:
        py = top + (from_ll.TransformPoint(lon_left, lat)[1] - y0) / dy * scale
        if top <= py <= top + mh:
            d.line([left - 6, py, left - 1, py], fill="black")
            label = f"{abs(lat):.{decimals_for(step)}f}°{'S' if lat < 0 else 'N'}"
            d.text((left - 9, py), label, fill="black", font=small, anchor="rm")

    # Color legend to the right of the map
    bx, bw = left + mw + 25, 18
    bar = np.linspace(vmax, vmin, mh)[:, None].repeat(bw, axis=1)
    canvas.paste(Image.fromarray(colorize(bar, vmin, vmax, ramp), "RGB"), (bx, top))
    d.rectangle([bx - 1, top - 1, bx + bw, top + mh], outline="black")
    d.text((bx, top - 14), units, fill="black", font=small, anchor="ls")
    ticks, step = nice_ticks(vmin, vmax, 5)
    for v in ticks:
        py = top + (vmax - v) / (vmax - vmin) * (mh - 1)
        d.line([bx + bw, py, bx + bw + 5, py], fill="black")
        d.text((bx + bw + 8, py), f"{v:,.{decimals_for(step)}f}", fill="black", font=small, anchor="lm")

    canvas.save(png)


def main():
    a = parse_args()

    if a.list:
        for db in a.databases:
            list_contents(db, a.table)
        return

    conns = [open_db(db, a.table, a.variable) for db in a.databases]
    base_conn = open_db(a.compare, a.table, a.variable) if a.compare else None
    years = pick_years(a.year, years_in(conns[0], a.table))

    os.makedirs(a.out_dir, exist_ok=True)
    name = a.name or os.path.splitext(os.path.basename(a.databases[0]))[0]
    if a.compare:
        name += "_minus_" + os.path.splitext(os.path.basename(a.compare))[0]

    for year in years:
        values = read_values(conns, a.table, a.variable, year)
        if a.compare:
            base = read_values([base_conn], a.table, a.variable, year)
            values = {k: v - base[k] for k, v in values.items() if k in base}
        if not values:
            print(f"Year {year}: no plots with values, skipped")
            continue

        xy, z, srs = project_points(values, a.epsg)
        tif = os.path.join(a.out_dir, f"{name}_{a.variable}_year{year}.tif")
        w, h = write_geotiff(xy, z, srs, a.cell_size, tif)
        print(f"Year {year}: {len(z)} plots -> {tif}  ({w} x {h} cells, "
              f"min {z.min():.1f}, mean {z.mean():.1f}, max {z.max():.1f})")

        if a.png:
            png = tif[:-4] + ".png"
            pretty = a.variable.replace("_", " ").capitalize()
            units = UNITS.get(a.variable, "")
            if a.compare:
                lim = a.vmax if a.vmax is not None else max(abs(z.min()), abs(z.max()), 1)
                base = os.path.splitext(os.path.basename(a.compare))[0]
                run = os.path.splitext(os.path.basename(a.databases[0]))[0]
                title = f"{pretty}: {run} minus {base}, year {year}"
                write_png(tif, png, -lim, lim, RAMP_DIFF, title, units)
            else:
                vmin = a.vmin if a.vmin is not None else z.min()
                vmax = a.vmax if a.vmax is not None else z.max()
                write_png(tif, png, vmin, vmax, RAMP, f"{pretty}, year {year}", units)
            print(f"         map -> {png}")


if __name__ == "__main__":
    main()
