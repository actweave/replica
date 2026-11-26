import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { AccessManagementPage } from "@pages/access-management-page"
import type { AccessManagementData } from "@pages/access-management-page/types"

export default function AccessManagementView() {
  return <AccessManagementPage data={useWorkspaceInbox(usePageData<AccessManagementData>())} />
}
