#!/usr/bin/env python3
import sqlite3
import os

def fix_database():
    if os.path.exists('golf_stats.db'):
        os.remove('golf_stats.db')
        print("Removed old database")
    
    conn = sqlite3.connect('golf_stats.db')
    c = conn.cursor()
    
    # Create tables with new schema
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
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (device_id) REFERENCES devices (device_id),
            UNIQUE(device_id, date)
        )
    ''')
    
    # Insert some test data
    test_devices = [
        ('4c30890501506046365aa689', '客厅设备'),
        ('112233445566778899aabbcc', '卧室设备'),
        ('ffeeddccbbaa998877665544', '办公室设备')
    ]
    
    for dev_id, name in test_devices:
        c.execute('INSERT OR IGNORE INTO devices (device_id, device_name) VALUES (?, ?)', (dev_id, name))
        
        # Add some test stats
        for day in range(1, 8):
            c.execute('''
                INSERT OR IGNORE INTO daily_stats (device_id, date, hit_count)
                VALUES (?, date('now', '-{} days'), ?)
            '''.format(day), (dev_id, day * 5))
    
    conn.commit()
    conn.close()
    print("Database fixed and test data added")

if __name__ == '__main__':
    fix_database()