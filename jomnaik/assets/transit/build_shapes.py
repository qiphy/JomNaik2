import zipfile
import csv
import json

# Native polyline encoder (No external pip packages needed!)
def encode_polyline(coordinates, precision=5):
    result = []
    multiplier = 10 ** precision
    last_lat, last_lon = 0, 0
    
    for lat, lon in coordinates:
        lat_int = int(round(lat * multiplier))
        lon_int = int(round(lon * multiplier))
        d_lat = lat_int - last_lat
        d_lon = lon_int - last_lon
        last_lat = lat_int
        last_lon = lon_int
        
        for v in [d_lat, d_lon]:
            v = ~(v << 1) if v < 0 else (v << 1)
            while v >= 0x20:
                result.append(chr((0x20 | (v & 0x1f)) + 63))
                v >>= 5
            result.append(chr(v + 63))
            
    return "".join(result)

def build_shapes(zip_path, output_path):
    print(f"Reading {zip_path}...")
    shapes = {} # Stores shape_id -> list of (lat, lon)
    route_shapes = {} # Maps route_id -> longest shape_id
    
    with zipfile.ZipFile(zip_path, 'r') as z:
        # 1. Read coordinates from shapes.txt
        with z.open('shapes.txt') as f:
            reader = csv.DictReader(f.read().decode('utf-8-sig').splitlines())
            for row in reader:
                shape_id = row['shape_id']
                if shape_id not in shapes:
                    shapes[shape_id] = []
                shapes[shape_id].append((
                    int(row['shape_pt_sequence']),
                    float(row['shape_pt_lat']),
                    float(row['shape_pt_lon'])
                ))
        
        # Sort coordinates into perfect lines
        for shape_id in shapes:
            shapes[shape_id].sort(key=lambda x: x[0])
            shapes[shape_id] = [(lat, lon) for seq, lat, lon in shapes[shape_id]]
            
        # 2. Match Route IDs to Shape IDs using trips.txt
        with z.open('trips.txt') as f:
            reader = csv.DictReader(f.read().decode('utf-8-sig').splitlines())
            for row in reader:
                route_id = row['route_id']
                shape_id = row.get('shape_id')
                if shape_id and shape_id in shapes:
                    if route_id not in route_shapes or len(shapes[shape_id]) > len(shapes.get(route_shapes[route_id], [])):
                        route_shapes[route_id] = shape_id
                        
    # 3. Encode the polylines and output the JSON
    print("Encoding polylines natively...")
    output_data = {}
    for route_id, shape_id in route_shapes.items():
        encoded = encode_polyline(shapes[shape_id], 5)
        output_data[route_id] = encoded
        
    with open(output_path, 'w') as out:
        json.dump(output_data, out)
        
    print(f"Success! Saved {len(output_data)} route shapes to {output_path}.")

# Run the builder
build_shapes('gtfs.zip', 'rail_shapes.json')