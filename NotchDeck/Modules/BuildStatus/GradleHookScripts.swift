import Foundation

/// Gradle init scripts installed by the "Install Gradle hook" button.
///
/// `notchdeck.gradle` (in ~/.gradle/init.d) is a tiny dispatcher that never breaks a build:
///  - Gradle >= 8.1: applies `~/.gradle/notchdeck/notchdeck-flow.gradle`, a Settings plugin using the
///    Flow API (`FlowScope` + `FlowProviders.buildWorkResult`), which is configuration-cache safe.
///  - Older Gradle: best-effort `gradle.buildFinished` listener.
/// Records go to the NotchDeck spool directory (override: env NOTCHDECK_SPOOL).
enum GradleHookScripts {
    static let initScript = #"""
    // NotchDeck build hook (managed by NotchDeck - use Settings > Builds > Uninstall to remove).
    import org.gradle.util.GradleVersion

    try {
        def spoolPath = System.getenv('NOTCHDECK_SPOOL') ?: (System.getProperty('user.home') + '/Library/Application Support/NotchDeck/builds')
        if (GradleVersion.current() >= GradleVersion.version('8.1')) {
            def flow = new File(gradle.gradleUserHomeDir, 'notchdeck/notchdeck-flow.gradle')
            if (flow.isFile()) { apply from: flow }
        } else {
            // Best effort for old Gradle versions (buildFinished is not configuration-cache compatible).
            def nd = [id: UUID.randomUUID().toString(), started: System.currentTimeMillis(), project: null, tasks: '']
            def write = { String kind, Map extra ->
                try {
                    def dir = new File(spoolPath); dir.mkdirs()
                    def rec = [v: 1, id: nd.id, startId: nd.id, kind: kind, source: 'gradle', project: nd.project,
                               title: nd.tasks, cwd: nd.cwd, startedAt: nd.started / 1000.0] + extra
                    def tmp = new File(dir, ".${nd.id}.${kind}.tmp")
                    tmp.text = groovy.json.JsonOutput.toJson(rec)
                    tmp.renameTo(new File(dir, "${nd.id}.${kind}.json"))
                } catch (Throwable ignored) { }
            }
            gradle.settingsEvaluated { settings ->
                try {
                    if (settings.gradle.parent != null) return
                    def tasks = settings.gradle.startParameter.taskNames
                    if (tasks == null || tasks.isEmpty()) return
                    nd.project = settings.rootProject.name
                    nd.tasks = tasks.join(' ')
                    nd.cwd = settings.settingsDir.absolutePath
                    nd.active = true
                    write('start', [:])
                } catch (Throwable ignored) { }
            }
            gradle.buildFinished { result ->
                try {
                    if (!nd.active) return
                    def failure = result.failure
                    def msg = failure == null ? null : failure.message
                    write('done', [endedAt: System.currentTimeMillis() / 1000.0, exit: failure == null ? 0 : 1,
                                   message: msg == null ? null : msg.take(400), tail: msg == null ? null : msg.take(2000)])
                } catch (Throwable ignored) { }
            }
        }
    } catch (Throwable ignored) { }
    """#

    static let flow = #"""
// NotchDeck build hook - Flow API implementation (Gradle 8.1+, configuration-cache compatible).
// Managed by NotchDeck; removed by Settings > Builds > Uninstall.
import groovy.json.JsonOutput
import org.gradle.api.Plugin
import org.gradle.api.flow.BuildWorkResult
import org.gradle.api.flow.FlowAction
import org.gradle.api.flow.FlowParameters
import org.gradle.api.flow.FlowProviders
import org.gradle.api.flow.FlowScope
import org.gradle.api.initialization.Settings
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters
import org.gradle.build.event.BuildEventsListenerRegistry
import org.gradle.tooling.events.FinishEvent
import org.gradle.tooling.events.OperationCompletionListener
import org.gradle.tooling.events.task.TaskFinishEvent
import javax.inject.Inject

class NotchDeckSpool {
    static void write(String spool, String id, String kind, Map rec) {
        try {
            def dir = new File(spool)
            dir.mkdirs()
            def tmp = new File(dir, ".${id}.${kind}.tmp")
            tmp.text = JsonOutput.toJson(rec)
            tmp.renameTo(new File(dir, "${id}.${kind}.json"))
        } catch (Throwable ignored) { }
    }
}

interface NotchDeckProgressParams extends BuildServiceParameters {
    Property<String> getStartId()
    Property<String> getSpool()
    Property<String> getProjectName()
    Property<String> getTaskNames()
}

// Counts finished tasks (configuration-cache compatible) and publishes progress at most once a second.
abstract class NotchDeckProgressService implements BuildService<NotchDeckProgressParams>, OperationCompletionListener, AutoCloseable {
    private int done = 0
    private long lastWrite = 0L

    @Override
    void onFinish(FinishEvent event) {
        if (!(event instanceof TaskFinishEvent)) return
        done++
        long now = System.currentTimeMillis()
        if (now - lastWrite < 1000L) return
        lastWrite = now
        publish(false)
    }

    @Override
    void close() { publish(true) }

    private void publish(boolean last) {
        try {
            def id = parameters.startId.get()
            NotchDeckSpool.write(parameters.spool.get(), id, 'progress', [
                v: 1, id: id, startId: id, kind: 'progress', source: 'gradle',
                project: parameters.projectName.get(), title: parameters.taskNames.get(),
                done: done, last: last
            ])
        } catch (Throwable ignored) { }
    }
}

interface NotchDeckParams extends FlowParameters {
    @Input Property<String> getStartId()
    @Input Property<String> getProjectName()
    @Input Property<String> getTaskNames()
    @Input Property<String> getCwd()
    @Input Property<String> getSpool()
    @Input Property<BuildWorkResult> getWorkResult()
}

class NotchDeckFinishAction implements FlowAction<NotchDeckParams> {
    @Override
    void execute(NotchDeckParams p) {
        try {
            def failure = p.workResult.get().failure
            def failed = failure.isPresent()
            String msg = null
            if (failed) {
                Throwable t = failure.get()
                while (t.cause != null && t.cause != t) { t = t.cause }
                msg = (t.message ?: failure.get().message ?: failure.get().class.simpleName)
            }
            // On a configuration-cache hit the start record is stale, so each finish gets its own id
            // and points at the start record via startId (the app pairs them when it is still open).
            def finishId = UUID.randomUUID().toString()
            NotchDeckSpool.write(p.spool.get(), finishId, 'done', [
                v: 1, id: finishId, startId: p.startId.get(), kind: 'done', source: 'gradle',
                project: p.projectName.get(), title: p.taskNames.get(), cwd: p.cwd.get(),
                endedAt: System.currentTimeMillis() / 1000.0, exit: failed ? 1 : 0,
                message: msg == null ? null : msg.take(400), tail: msg == null ? null : msg.take(2000)
            ])
        } catch (Throwable ignored) { }
    }
}

class NotchDeckPlugin implements Plugin<Settings> {
    private final FlowScope flowScope
    private final FlowProviders flowProviders

    private final BuildEventsListenerRegistry listenerRegistry

    @Inject
    NotchDeckPlugin(FlowScope flowScope, FlowProviders flowProviders, BuildEventsListenerRegistry listenerRegistry) {
        this.flowScope = flowScope
        this.flowProviders = flowProviders
        this.listenerRegistry = listenerRegistry
    }

    @Override
    void apply(Settings settings) {
        try {
            if (settings.gradle.parent != null) return          // buildSrc / included builds
            def tasks = settings.gradle.startParameter.taskNames
            if (tasks == null || tasks.isEmpty()) return        // IDE sync / model fetching
            def spool = System.getenv('NOTCHDECK_SPOOL') ?: (System.getProperty('user.home') + '/Library/Application Support/NotchDeck/builds')
            String startId = UUID.randomUUID().toString()
            String project = settings.rootProject.name
            String taskText = tasks.join(' ')
            String cwd = settings.settingsDir.absolutePath
            NotchDeckSpool.write(spool, startId, 'start', [
                v: 1, id: startId, startId: startId, kind: 'start', source: 'gradle',
                project: project, title: taskText, cwd: cwd,
                startedAt: System.currentTimeMillis() / 1000.0
            ])
            try {
                def service = settings.gradle.sharedServices.registerIfAbsent('notchdeckProgress', NotchDeckProgressService) { spec ->
                    spec.parameters.startId.set(startId)
                    spec.parameters.spool.set(spool)
                    spec.parameters.projectName.set(project)
                    spec.parameters.taskNames.set(taskText)
                }
                listenerRegistry.onTaskCompletion(service)
            } catch (Throwable ignored) { }
            flowScope.always(NotchDeckFinishAction) { spec ->
                spec.parameters.startId.set(startId)
                spec.parameters.projectName.set(project)
                spec.parameters.taskNames.set(taskText)
                spec.parameters.cwd.set(cwd)
                spec.parameters.spool.set(spool)
                spec.parameters.workResult.set(flowProviders.buildWorkResult)
            }
        } catch (Throwable ignored) { }
    }
}

// rootProject.name is final only after settings.gradle ran, hence settingsEvaluated.
gradle.settingsEvaluated { settings ->
    try { settings.pluginManager.apply(NotchDeckPlugin) } catch (Throwable ignored) { }
}
"""#
}
