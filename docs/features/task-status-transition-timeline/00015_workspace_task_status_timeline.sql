-- +goose Up
CREATE TABLE IF NOT EXISTS workspace_task_status_timeline (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  UUID        NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
    feature_id    UUID        NOT NULL REFERENCES workspace_features (id) ON DELETE CASCADE,
    task_id       UUID        NOT NULL REFERENCES workspace_tasks (id) ON DELETE CASCADE,
    task_name     TEXT        NOT NULL,
    status        TEXT        NOT NULL,
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_timeline_time_order CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_task_timeline_one_active
    ON workspace_task_status_timeline (task_id)
    WHERE ended_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_task_timeline_time
    ON workspace_task_status_timeline (task_id, started_at);

CREATE OR REPLACE FUNCTION fn_task_status_timeline_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        UPDATE workspace_task_status_timeline
        SET ended_at = now()
        WHERE task_id = NEW.id AND ended_at IS NULL;

        IF NEW.status IS NOT NULL AND NEW.status != '' THEN
            INSERT INTO workspace_task_status_timeline
                (workspace_id, feature_id, task_id, task_name, status, started_at)
            VALUES
                (NEW.workspace_id, NEW.feature_id, NEW.id, NEW.task_name, NEW.status, now());
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_task_status_timeline_change
    AFTER UPDATE OF status ON workspace_tasks
    FOR EACH ROW
    EXECUTE FUNCTION fn_task_status_timeline_change();

-- +goose Down
DROP TRIGGER IF EXISTS trg_task_status_timeline_change ON workspace_tasks;
DROP FUNCTION IF EXISTS fn_task_status_timeline_change();
DROP TABLE IF EXISTS workspace_task_status_timeline;
