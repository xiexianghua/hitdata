from flask import Flask, request, jsonify, render_template
from datetime import datetime
import sqlite3
import os
import json

app = Flask(__name__)

# Database initialization
def init_db():
    conn = sqlite3.connect('data/golf_stats.db')
    c = conn.cursor()
    
    # Create tables
    c.execute('''
        CREATE TABLE IF NOT EXISTS devices (
            device_id TEXT PRIMARY KEY,
            device_name TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    c.execute('''
        CREATE TABLE IF NOT EXISTS daily_stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT,
            date TEXT,
            hit_count INTEGER,
            firmware_version TEXT DEFAULT 'unknown',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (device_id) REFERENCES devices (device_id),
            UNIQUE(device_id, date, firmware_version)
        )
    ''')
    
    conn.commit()
    conn.close()

# API endpoint to receive golf stats
@app.route('/api/golf_stats', methods=['POST'])
def receive_golf_stats():
    try:
        data = request.get_json()
        
        if not data or 'device_id' not in data or 'daily_data' not in data:
            return jsonify({'error': 'Invalid data format'}), 400
        
        device_id = data['device_id']
        daily_data = data['daily_data']
        firmware_version = data.get('firmware_version', 'unknown')

        conn = sqlite3.connect('data/golf_stats.db')
        c = conn.cursor()

        # Insert or ignore device
        c.execute('''
            INSERT OR IGNORE INTO devices (device_id) VALUES (?)
        ''', (device_id,))

        # Insert or update daily stats
        for date_str, hit_count in daily_data.items():
            c.execute('''
                INSERT INTO daily_stats (device_id, date, hit_count, firmware_version)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(device_id, date, firmware_version) DO UPDATE SET
                hit_count = hit_count + excluded.hit_count
            ''', (device_id, date_str, hit_count, firmware_version))
        
        conn.commit()
        conn.close()
        
        return jsonify({'status': 'success'}), 201
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# Dashboard endpoint
@app.route('/')
def dashboard():
    return render_template('dashboard.html')

# API endpoint to get stats data for the dashboard
@app.route('/api/dashboard_data')
def get_dashboard_data():
    try:
        conn = sqlite3.connect('data/golf_stats.db')
        c = conn.cursor()
        
        query = '''
            SELECT ds.device_id, ds.date, ds.hit_count, d.created_at, d.device_name, ds.firmware_version
            FROM daily_stats ds
            JOIN devices d ON ds.device_id = d.device_id
            ORDER BY ds.firmware_version, ds.date DESC
        '''
        
        c.execute(query)
        rows = c.fetchall()
        conn.close()
        
        # Group data by device, and then by firmware version
        device_data = {}
        for device_id, date, hit_count, created_at, device_name, fw_version in rows:
            if device_id not in device_data:
                device_data[device_id] = {
                    'device_id': device_id,
                    'device_name': device_name or f'设备 {device_id[-8:].upper()}',
                    'created_at': created_at,
                    'stats_by_version': {}
                }
            
            if fw_version not in device_data[device_id]['stats_by_version']:
                device_data[device_id]['stats_by_version'][fw_version] = []
            
            device_data[device_id]['stats_by_version'][fw_version].append({
                'date': date,
                'hit_count': hit_count
            })
        
        return jsonify(list(device_data.values()))
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# API endpoint to get all unique firmware versions
@app.route('/api/firmware_versions')
def get_firmware_versions():
    try:
        conn = sqlite3.connect('data/golf_stats.db')
        c = conn.cursor()
        
        c.execute('SELECT DISTINCT firmware_version FROM daily_stats ORDER BY firmware_version DESC')
        
        versions = [row[0] for row in c.fetchall()]
        conn.close()
        
        return jsonify(versions)
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# API endpoint to rename a device
@app.route('/api/devices/<device_id>/rename', methods=['PUT'])
def rename_device(device_id):
    try:
        data = request.get_json()
        new_name = data.get('device_name')
        
        if not new_name or not new_name.strip():
            return jsonify({'error': 'Device name cannot be empty'}), 400
        
        conn = sqlite3.connect('data/golf_stats.db')
        c = conn.cursor()
        
        # Check if device exists
        c.execute('SELECT device_id FROM devices WHERE device_id = ?', (device_id,))
        if not c.fetchone():
            conn.close()
            return jsonify({'error': 'Device not found'}), 404
        
        # Update device name
        c.execute('UPDATE devices SET device_name = ? WHERE device_id = ?', (new_name.strip(), device_id))
        conn.commit()
        conn.close()
        
        return jsonify({'status': 'success', 'device_name': new_name.strip()}), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# API endpoint to delete a device
@app.route('/api/devices/<device_id>', methods=['DELETE'])
def delete_device(device_id):
    try:
        conn = sqlite3.connect('data/golf_stats.db')
        c = conn.cursor()
        
        # Check if device exists
        c.execute('SELECT device_id FROM devices WHERE device_id = ?', (device_id,))
        if not c.fetchone():
            conn.close()
            return jsonify({'error': 'Device not found'}), 404
        
        # Delete device and all associated stats (cascade deletion)
        c.execute('DELETE FROM daily_stats WHERE device_id = ?', (device_id,))
        c.execute('DELETE FROM devices WHERE device_id = ?', (device_id,))
        conn.commit()
        conn.close()
        
        return jsonify({'status': 'success'}), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=5000, debug=True)