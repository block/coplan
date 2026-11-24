import { Application } from "@hotwired/stimulus"
import AdminCommentDeletionController from "controllers/coplan/admin_comment_deletion_controller"

const application = Application.start()
application.register("coplan--admin-comment-deletion", AdminCommentDeletionController)
