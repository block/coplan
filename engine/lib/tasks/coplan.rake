# Automatically copy engine migrations before db:migrate so hosts
# never silently fall behind on schema changes.
# Rails derives the task name from CoPlan → co_plan.
Rake::Task["db:migrate"].enhance(["co_plan:install:migrations"]) if Rake::Task.task_defined?("db:migrate")
