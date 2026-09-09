import zipfile
import csv
import json
from collections import defaultdict

def time_to_seconds(time_str):
    """Converts GTFS HH:MM:SS to total seconds from midnight."""
    try:
        h, m, s = map(int, time_str.split(':'))
        return h * 3600 + m * 60 + s
    except:
        return None

def build_graph(zip_path, output_path):
    print(f"Reading {zip_path}...")
    
    # We will store the shortest travel time between any two adjacent stops
    # Format: edges[from_stop][to_stop] = time_in_seconds
    edges = defaultdict(dict)
    
    with zipfile.ZipFile(zip_path, 'r') as z:
        # Read stop_times.txt to find consecutive stops on the same trip
        with z.open('stop_times.txt') as f:
            reader = csv.DictReader(f.read().decode('utf-8').splitlines())
            
            # Group rows by trip_id
            trips = defaultdict(list)
            for row in reader:
                trips[row['trip_id']].append({
                    'stop_id': row['stop_id'],
                    'stop_sequence': int(row['stop_sequence']),
                    'arrival_time': time_to_seconds(row['arrival_time']),
                    'departure_time': time_to_seconds(row['departure_time'])
                })
        
        print("Processing connections...")
        # Sort each trip by sequence and create edges
        for trip_id, stops in trips.items():
            stops.sort(key=lambda x: x['stop_sequence'])
            
            for i in range(len(stops) - 1):
                from_stop = stops[i]
                to_stop = stops[i+1]
                
                # Calculate travel time
                if from_stop['departure_time'] is not None and to_stop['arrival_time'] is not None:
                    travel_time = to_stop['arrival_time'] - from_stop['departure_time']
                    
                    if travel_time >= 0:
                        current_best = edges[from_stop['stop_id']].get(to_stop['stop_id'], float('inf'))
                        if travel_time < current_best:
                            edges[from_stop['stop_id']][to_stop['stop_id']] = travel_time

    # Format for Flutter
    flutter_graph = []
    for from_node, destinations in edges.items():
        for to_node, travel_time in destinations.items():
            flutter_graph.append({
                "from": from_node,
                "to": to_node,
                "time": travel_time
            })
            
    print(f"Found {len(flutter_graph)} unique station connections.")
    
    with open(output_path, 'w') as out:
        json.dump(flutter_graph, out)
        
    print(f"Successfully saved to {output_path}! File size is tiny.")

# Run the builder
build_graph('gtfs.zip', 'graph.json')