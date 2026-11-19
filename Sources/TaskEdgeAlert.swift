import Foundation

@MainActor
final class TaskEdgeAlert {
    private struct Deadline: Hashable {
        let id: String
        let date: Date
    }

    private var tasks: [TaskItem] = []
    private var acknowledged: Set<Deadline> = []
    private var due: Set<Deadline> = []
    private var visibleTasks: [TaskItem] = []
    private var timer: Timer?
    private var scheduledDate: Date?
    private let update: ([TaskItem], Set<String>) -> Void

    init(update: @escaping ([TaskItem], Set<String>) -> Void) {
        self.update = update
    }

    func replaceTasks(_ tasks: [TaskItem]) {
        self.tasks = tasks
        reconcile()
    }

    func acknowledge(taskID: String? = nil) {
        acknowledged.formUnion(due.filter { taskID == nil || $0.id == taskID })
        reconcile()
    }

    func reconcile() {
        let now = Date()
        let timedTasks = tasks.compactMap { task -> (Deadline, TaskItem)? in
            guard !task.completed, task.due?.hour != nil, let date = task.dueDate else { return nil }
            return (Deadline(id: task.id, date: date), task)
        }
        let deadlines = Set(timedTasks.map { $0.0 })
        acknowledged.formIntersection(deadlines)
        let previouslyDue = due
        due = Set(deadlines.filter { $0.date <= now }).subtracting(acknowledged)
        let nextVisibleTasks = timedTasks.filter { due.contains($0.0) }
            .sorted { $0.0.date == $1.0.date ? $0.0.id < $1.0.id : $0.0.date < $1.0.date }
            .map { $0.1 }
        if visibleTasks != nextVisibleTasks || due != previouslyDue {
            visibleTasks = nextVisibleTasks
            update(visibleTasks, Set(due.subtracting(previouslyDue).map(\.id)))
        }
        let next = deadlines.lazy.map(\.date).filter { $0 > now }.min()
        guard next != scheduledDate else { return }
        timer?.invalidate()
        timer = nil
        scheduledDate = next
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduledDate = nil
                self?.timer = nil
                self?.reconcile()
            }
        }
        timer.tolerance = 0.5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func resetClock() {
        timer?.invalidate()
        timer = nil
        scheduledDate = nil
        reconcile()
    }
}
