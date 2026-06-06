from flask import Flask, request, jsonify
import heapq
import os

app = Flask(__name__)

meetings_heap = []

@app.route("/")
def home_page():
    return "Welcome to the home page!"

# scheduale a new meeting with curl command (examples in the end of the script)
@app.route('/schedule', methods=['GET', 'POST'])
def new_schedule():
    if request.method == 'POST':
        new_schedule = request.get_json()
        title = new_schedule.get('title')
        start = int(new_schedule.get('start'))
        duration = int(new_schedule.get('duration'))
        
        # Calculate end_time with proper hour handling
        end_time = start + duration
        
        # Handle minute overflow (e.g., 1340 + 30 = 1410, but 1350 + 20 = 1410 not 1370)
        start_hour = start // 100
        start_min = start % 100
        
        end_min = start_min + duration
        end_hour = start_hour
        
        while end_min >= 60:
            end_min -= 60
            end_hour += 1
        
        end_time = end_hour * 100 + end_min
        
        has_conflict = False
        conflict_title = ""
        
        for meeting in meetings_heap:
            existing_start = meeting[0]
            existing_end = meeting[1]
            existing_title = meeting[2]
            
            # Check if new meeting overlaps with existing meeting
            if start < existing_end and end_time > existing_start:
                has_conflict = True
                conflict_title = existing_title
                break
        
        # If there's a conflict, return error
        if has_conflict:
            return jsonify({
                "error": "Conflict detected",
                "message": f"Meeting '{title}' conflicts with existing meeting '{conflict_title}'"
            }), 400
        
        # No conflict - add to heap
        meeting_tuple = (start, end_time, title)
        heapq.heappush(meetings_heap, meeting_tuple)
        
        # Return all meetings in JSON format
        return jsonify({
            "message": "Meeting scheduled successfully",
            "meetings": [
                {"start": m[0], "end": m[1], "title": m[2]} 
                for m in sorted(meetings_heap)
            ]
        }), 201
    
    elif request.method == 'GET':
        # Return all scheduled meetings
        return jsonify({
            "meetings": [
                {"start": m[0], "end": m[1], "title": m[2]} 
                for m in sorted(meetings_heap)
            ]
        })

 # change URL to check what is the soonest next meeting   
@app.route('/next', methods=['GET'])
def next_meeting_is():
    if not meetings_heap:
        return jsonify({"error": "No meetings scheduled"}), 404
    
    next_meeting = meetings_heap[0]
    return jsonify({
        "meeting": {
            "start": next_meeting[0], 
            "end": next_meeting[1], 
            "title": next_meeting[2]
        }
    }), 200

# change URL to update the meetings schedule by removing the meeting that was completed
@app.route('/complete', methods=['GET','POST']) 
def remove_the_earliest_meeting():
    if not meetings_heap:
        return jsonify({"error": "No meetings to complete"}), 404
    
    heapq.heappop(meetings_heap)
    return jsonify({
        "message": "Meeting completed",
        "meetings": [
            {"start": m[0], "end": m[1], "title": m[2]} 
            for m in sorted(meetings_heap)
        ]
    }), 200

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    app.run(debug=True, host='0.0.0.0', port=port)




# curl -X POST http://localhost:5000/schedule -H "Content-Type: application/json" -d '{"title": "sync meeting", "start": 1300, "duration": 60}'
# curl -X POST http://localhost:5000/schedule -H "Content-Type: application/json" -d '{"title": "lunch", "start": 1330, "duration": 60}'
# curl -X POST http://localhost:5000/schedule -H "Content-Type: application/json" -d '{"title": "standup", "start": 1000, "duration": 90}'
# curl -X POST http://localhost:5000/schedule -H "Content-Type: application/json" -d '{"title": "one on one", "start": 800, "duration": 20}'
# curl -X POST http://localhost:5000/schedule -H "Content-Type: application/json" -d '{"title": "cross skilling", "start": 1200, "duration": 40}'